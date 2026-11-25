#!/usr/bin/env bash
# find-ticket-sessions.sh — For each ticket key, rank local Claude Code sessions
#                           by how likely they worked on that ticket.
#
# Usage:
#   find-ticket-sessions.sh [exclude_session_id] < tickets.json
#
#   stdin               [{"ticket": "YOU-123", "branch": "kinano/you-123-foo"}, ...]
#                       "branch" is optional ("" or missing = unknown). Keys
#                       are a letter, then letters, digits or "_", then
#                       -<digits> (YOU-123, MY_PROJ-12). Keys are uppercased
#                       and deduplicated (the first non-empty branch wins).
#   exclude_session_id  optional: skip the transcript with this session id.
#                       Defaults to $CLAUDE_CODE_SESSION_ID (the calling
#                       session), whose transcript mentions every ticket.
#
# Prints {"<TICKET>": [candidates...], ...}. Every input ticket (uppercased)
# is a key, possibly with []. A usage error (malformed stdin) exits 2. If the
# transcript scan fails, the script prints ERROR on stderr, nothing on stdout,
# and exits 1: no output means "unknown", never "no sessions".
#
# Environment:
#   CLAUDE_PROJECTS_DIR   transcript root (default: ~/.claude/projects)
#   RCS_MAX_AGE_DAYS      only scan transcripts modified in the last N days
#                         (default: 30; 0 scans everything)
#
# Transcripts are read one level deep: <projects>/<project>/<session-id>.jsonl.
# Subagent transcripts in deeper folders are ignored.
#
# Candidate fields:
#   session_id    transcript file stem (use with `claude --resume`)
#   agent_name    last top-level agentName of an agent-name record, else null.
#                 The only field to match against ListAgents rows.
#   custom_title  last top-level customTitle, else null
#   cwd           launch dir: first top-level cwd
#   cwd_exists    cwd is an existing directory
#   git_branch    last top-level gitBranch
#   signals       subset of ["branch","name","mention"]
#   score         branch 4 + name 4 + mention 1
#   confidence    "strong" iff branch or name, else "weak"
#   mentions      how many of the input tickets this transcript mentions
#   last_active   transcript mtime, epoch seconds
#
# Signals (ticket keys match case-insensitively on token boundaries, so YOU-1
# does not match YOU-10, XYOU-1 or X_YOU-1):
#   branch   a top-level gitBranch equals the ticket's branch, or contains the
#            ticket key (e.g. kinano/you-123-fix-login)
#   name     agent_name or custom_title contains the ticket key
#   mention  the transcript text mentions the ticket key
#
# A mention-only candidate whose transcript mentions 3+ of the input tickets is
# dropped: that is a triage/report session (an earlier run of this skill,
# /pr-action-board, a standup), not the session that owns the ticket. How many
# were dropped is printed on stderr as a NOTE line.
#
# Sorted strong first, then score, then recency; at most 5 per ticket.
# A find error is reported as a WARN on stderr; the exit status stays 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../../_shared/transcripts.sh
source "$SCRIPT_DIR/../../_shared/transcripts.sh"

usage_error() {
  echo "ERROR: $1" >&2
  echo "Usage: find-ticket-sessions.sh [exclude_session_id] < tickets.json" >&2
  exit 2
}

[[ $# -le 1 ]] || usage_error "too many arguments"
EXCLUDE_ID="${1-${CLAUDE_CODE_SESSION_ID-}}"

if ! TICKETS_JSON="$(jq -ce '
      if type == "array" and all(.[];
           type == "object"
           and (.ticket | type == "string" and test("^[A-Za-z][A-Za-z0-9_]*-[0-9]+$"))
           and ((.branch // "") | type == "string"))
      then map({ticket: (.ticket | ascii_upcase), branch: (.branch // "")})
        | reduce .[] as $t ([];
            (map(.ticket == $t.ticket) | index(true)) as $i
            | if $i == null then . + [$t]
              elif .[$i].branch == "" then .[$i].branch = $t.branch
              else . end)
      else error("bad input") end' 2>/dev/null)"; then
  usage_error "stdin must be a JSON array of {ticket, branch?} with keys like ABC-123"
fi

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
MAX_AGE_DAYS="$(transcripts_max_age RCS_MAX_AGE_DAYS 30)"

# Scan records are {ticket, candidate} or a trailing {dropped: N}.
# shellcheck disable=SC2016  # jq source
AGGREGATE_JQ='
  (reduce (.[] | select(.candidate)) as $r ({}; .[$r.ticket] += [$r.candidate])) as $by
  | reduce $tickets[] as $t ({};
      .[$t.ticket] = (($by[$t.ticket] // [])
        | sort_by((if .confidence == "strong" then 0 else 1 end), -.score, -(.last_active // 0))
        | .[:5]))'

emit() { jq -s --argjson tickets "$TICKETS_JSON" "$AGGREGATE_JQ"; }

if [[ "$TICKETS_JSON" == "[]" ]]; then
  emit </dev/null
  exit 0
fi
if [[ ! -d "$PROJECTS_DIR" ]]; then
  echo "WARN: Claude projects dir not found: $PROJECTS_DIR" >&2
  emit </dev/null
  exit 0
fi

# One perl pass over raw JSONL bytes; the line helpers live in _shared/TranscriptScan.pm.
# shellcheck disable=SC2016  # perl source
SCAN_PERL='
use strict;
use warnings;
no warnings "regexp";
use Encode qw(decode_utf8 encode_utf8);
use JSON::PP;
use TranscriptScan qw(json_str session_meta ticket_re ticket_hits);

my $out     = JSON::PP->new->utf8->canonical;
my $excl_id = decode_utf8($ENV{RCS_EXCLUDE_ID} // "");
my @tickets = @{ decode_json($ENV{RCS_TICKETS}) };
my %branch_of = map { lc($_->{ticket}) => lc($_->{branch}) } @tickets;
my @keys      = map { lc $_->{ticket} } @tickets;
my $tkt_re    = ticket_re(@keys);
my $dropped   = 0;

sub keys_in {
  my ($text) = @_;
  my %k;
  return \%k unless defined $text;
  ticket_hits($tkt_re, encode_utf8($text), \%k);
  return \%k;
}

for my $file (@ARGV) {
  (my $sid = $file) =~ s{.*/}{};
  $sid =~ s/\.jsonl\z//;
  $sid = decode_utf8($sid);
  next if length $excl_id && $sid eq $excl_id;

  open(my $fh, "<:raw", $file) or do { warn "WARN: cannot read $file: $!\n"; next };
  my (%m, %hit);
  while (my $line = <$fh>) {
    session_meta(\%m, $line);
    ticket_hits($tkt_re, $line, \%hit) if keys %hit < @keys;
  }
  my $mtime = (stat $fh)[9];
  close $fh;
  next unless defined $mtime;
  my ($agent, $title, $cwd_raw, $branch_raw) = @m{qw(agent title cwd_raw branch_raw)};

  my @branch_text = map { json_str($_) } keys %{ $m{branches} || {} };
  my %branch_lc   = map { lc($_) => 1 } @branch_text;
  my %branch_keys = map { %{ keys_in($_) } } @branch_text;
  my %name_keys   = (%{ keys_in($agent) }, %{ keys_in($title) });
  my $mentions    = scalar keys %hit;
  my $cwd         = defined $cwd_raw ? json_str($cwd_raw) : undef;

  for my $t (@tickets) {
    my $k = lc $t->{ticket};
    my (@signals, $score);
    $score = 0;
    my $br = $branch_of{$k};
    if ((length $br && $branch_lc{$br}) || $branch_keys{$k}) { push @signals, "branch";  $score += 4 }
    if ($name_keys{$k})                                     { push @signals, "name";    $score += 4 }
    if ($hit{$k})                                           { push @signals, "mention"; $score += 1 }
    next unless $score;
    my $strong = $score >= 4;
    if (!$strong && $mentions >= 3) { $dropped++; next }

    print $out->encode({
      ticket    => $t->{ticket},
      candidate => {
        session_id   => $sid,
        agent_name   => $agent,
        custom_title => $title,
        cwd          => $cwd,
        cwd_exists   => (defined $cwd && -d encode_utf8($cwd)) ? JSON::PP::true : JSON::PP::false,
        git_branch   => defined $branch_raw ? json_str($branch_raw) : undef,
        signals      => \@signals,
        score        => $score,
        confidence   => $strong ? "strong" : "weak",
        mentions     => $mentions,
        last_active  => $mtime + 0,
      },
    }), "\n";
  }
}
print $out->encode({ dropped => $dropped }), "\n" if $dropped;
'

# Buffer the scan so a failed scan prints nothing rather than empty results.
SCAN_OUT="$(mktemp)"
trap 'rm -f "$SCAN_OUT"' EXIT
if ! transcripts_list "$PROJECTS_DIR" "$MAX_AGE_DAYS" \
     | RCS_TICKETS="$TICKETS_JSON" RCS_EXCLUDE_ID="$EXCLUDE_ID" \
       xargs -0 perl -I"$TRANSCRIPT_SHARED_DIR" -e "$SCAN_PERL" >"$SCAN_OUT"; then
  echo "ERROR: transcript scan failed; results unknown" >&2
  exit 1
fi
# xargs may run perl more than once, so sum the per-run counts.
DROPPED="$(jq -s '[.[].dropped // 0] | add // 0' "$SCAN_OUT")"
if [[ "$DROPPED" -gt 0 ]]; then
  echo "NOTE: dropped $DROPPED mention-only triage candidates (transcripts mentioning 3+ input tickets)" >&2
fi
emit <"$SCAN_OUT"
