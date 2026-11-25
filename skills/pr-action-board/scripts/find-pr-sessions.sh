#!/usr/bin/env bash
# find-pr-sessions.sh — Rank local Claude Code sessions by how likely they are
#                       to own a PR (opened it, or worked on its branch/ticket).
#
# Usage:
#   find-pr-sessions.sh <pr_url> <head_ref> <ticket_or_empty> [exclude_agent_name] [exclude_session_id]
#   find-pr-sessions.sh --batch [exclude_agent_name] [exclude_session_id] < prs.json
#
#   pr_url              https://github.com/<owner>/<repo>/pull/<n>; the PR's
#                       repo is parsed from it
#   head_ref            the PR's head branch, e.g. YOU-9630-logo-route
#   ticket_or_empty     e.g. YOU-9630, or "" when the PR has no ticket key
#   exclude_agent_name  optional: skip transcripts whose agent_name equals this
#                       (the calling session's own name)
#   exclude_session_id  optional: skip the transcript with this session id
#
# Batch mode reads [{"pr_url", "head_ref", "ticket"}, ...] on stdin, scans the
# transcripts once, and prints {"<pr_url>": [candidates...], ...}. Every input
# pr_url is a key, possibly with []. Single mode prints the candidate array.
# A usage error (bad arguments, invalid URL, malformed stdin) exits 2.
#
# Environment:
#   CLAUDE_PROJECTS_DIR        transcript root (default: ~/.claude/projects)
#   PR_SESSIONS_MAX_AGE_DAYS   only scan transcripts modified in the last N days
#                              (default: 14; 0 scans everything)
#
# Transcripts are read one level deep: <projects>/<project>/<session-id>.jsonl.
# Subagent transcripts in deeper folders are ignored.
#
# Candidate fields:
#   session_id    transcript file stem
#   agent_name    last top-level agentName of an agent-name record, else null
#   custom_title  last top-level customTitle, else null (informational only)
#   cwd           launch dir: first top-level cwd
#   last_cwd      last top-level cwd
#   cwd_exists    cwd is an existing directory
#   git_branch    last top-level gitBranch
#   repo          owner/repo of `git -C <cwd> remote get-url origin`, lowercased,
#                 or null when unknown
#   repo_match    repo == the PR's repo; null when repo is unknown
#   name_kind     "exact" (agent_name == head_ref, case-insensitive),
#                 "ticket_prefix" (agent_name starts with ticket + / - _ space),
#                 or null
#   score         branch 4 + name 4 + pr_url 2 + ticket 1
#   confidence    "strong" iff repo_match is true AND (branch OR name_kind exact)
#   signals       subset of ["branch","name","pr_url","ticket"]
#   last_active   transcript mtime, epoch seconds
#
# Signals:
#   branch  a top-level gitBranch equals head_ref
#   name    name_kind is not null
#   pr_url  the transcript mentions the PR URL (pull/12 does not match pull/123)
#   ticket  the transcript mentions the ticket key (case-insensitive;
#           YOU-1 does not match YOU-10, XYOU-1 or X_YOU-1)
#
# Sorted strong first, then score, then recency; at most 10 per PR.
#
# A find error (unreadable folder, folder removed mid-scan) is reported as a
# WARN on stderr; the exit status stays 0. If the transcript scan itself fails,
# the script prints ERROR on stderr, nothing on stdout, and exits 1: no output
# means "unknown", never "no sessions".
#
# The scan is one perl pass that never fully decodes large lines: macOS grep and
# pure-perl JSON decoding are both far too slow over gigabytes of JSONL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../../_shared/transcripts.sh
source "$SCRIPT_DIR/../../_shared/transcripts.sh"

USAGE="Usage: find-pr-sessions.sh <pr_url> <head_ref> <ticket_or_empty> [exclude_agent_name] [exclude_session_id]
       find-pr-sessions.sh --batch [exclude_agent_name] [exclude_session_id] < prs.json"

usage_error() {
  echo "ERROR: $1" >&2
  echo "$USAGE" >&2
  exit 2
}

PR_URL_RE='^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$'

MODE="single"
if [[ "${1-}" == "--batch" ]]; then
  MODE="batch"
  [[ $# -le 3 ]] || usage_error "too many arguments for --batch"
  EXCLUDE_NAME="${2-}"
  EXCLUDE_ID="${3-}"
  if ! PRS_JSON="$(jq -ce --arg re "$PR_URL_RE" '
        if type == "array" and all(.[];
             type == "object"
             and (.pr_url | type == "string" and test($re))
             and (.head_ref | type == "string" and length > 0)
             and ((.ticket // "") | type == "string"))
        then map({pr_url, head_ref, ticket: (.ticket // "")})
        else error("bad batch input") end' 2>/dev/null)"; then
    usage_error "stdin must be a JSON array of {pr_url, head_ref, ticket} with GitHub PR URLs"
  fi
else
  [[ $# -ge 3 && $# -le 5 ]] || usage_error "expected 3 to 5 arguments"
  [[ "$1" =~ $PR_URL_RE ]] || usage_error "not a GitHub PR URL: $1"
  [[ -n "$2" ]] || usage_error "head_ref must not be empty"
  SINGLE_URL="$1"
  EXCLUDE_NAME="${4-}"
  EXCLUDE_ID="${5-}"
  PRS_JSON="$(jq -cn --arg u "$1" --arg h "$2" --arg t "$3" '[{pr_url: $u, head_ref: $h, ticket: $t}]')"
fi

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
MAX_AGE_DAYS="$(transcripts_max_age PR_SESSIONS_MAX_AGE_DAYS 14)"

# Group per-transcript records by PR, keep every input PR as a key, rank, cap.
# shellcheck disable=SC2016  # jq source: $vars belong to jq, not bash
AGGREGATE_JQ='
  (reduce .[] as $r ({}; .[$r.pr_url] += [$r.candidate])) as $by_pr
  | reduce $prs[] as $p ({};
      .[$p.pr_url] = (($by_pr[$p.pr_url] // [])
        | sort_by((if .confidence == "strong" then 0 else 1 end), -.score, -(.last_active // 0))
        | .[:10]))
  | if $mode == "single" then .[$url] else . end'

emit() {
  jq -s --argjson prs "$PRS_JSON" --arg mode "$MODE" --arg url "${SINGLE_URL-}" "$AGGREGATE_JQ"
}

if [[ ! -d "$PROJECTS_DIR" ]]; then
  echo "WARN: Claude projects dir not found: $PROJECTS_DIR" >&2
  emit </dev/null
  exit 0
fi

# One JSON line per (transcript, PR) pair that matched at least one signal:
#   {"pr_url": ..., "candidate": {...}}
# Lines are matched as raw UTF-8 bytes; names are compared as decoded text;
# output is UTF-8 encoded.
# shellcheck disable=SC2016  # perl source: $vars belong to perl, not bash
SCAN_PERL='
use strict;
use warnings;
no warnings "regexp";
use Encode qw(decode_utf8 encode_utf8);
use JSON::PP;
use TranscriptScan qw(json_str session_meta ticket_re ticket_hits);

my $out     = JSON::PP->new->utf8->canonical;
my $exclude = decode_utf8($ENV{FPS_EXCLUDE_NAME} // "");
my $excl_id = decode_utf8($ENV{FPS_EXCLUDE_ID} // "");

# PRs: decoded text for comparisons, UTF-8 bytes for matching raw lines.
my @prs;
for my $p (@{ decode_json($ENV{FPS_PRS}) }) {
  my ($owner, $repo) = $p->{pr_url} =~ m{^https://github\.com/([^/]+)/([^/]+)/pull/}
    or die "bad pr_url: $p->{pr_url}\n";
  push @prs, {
    url    => $p->{pr_url},
    repo   => lc "$owner/$repo",
    head   => $p->{head_ref},
    ticket => $p->{ticket} // "",
  };
}

my @urls    = map { encode_utf8($_->{url}) } @prs;
my $url_alt = join "|", map { quotemeta } sort { length $b <=> length $a } @urls;
my $url_re  = qr/($url_alt)(?![0-9])/;
my @tickets = grep { length } map { encode_utf8(lc $_->{ticket}) } @prs;
my $tkt_re  = ticket_re(@tickets);
my %n_url   = map { $_ => 1 } @urls;
my %n_tkt   = map { $_ => 1 } @tickets;

my %repo_cache;
sub repo_of {
  my ($dir) = @_;
  return undef unless defined $dir && -d encode_utf8($dir);
  return $repo_cache{$dir} if exists $repo_cache{$dir};
  my $url = "";
  my $pid = open(my $git, "-|");
  if (!defined $pid) { return $repo_cache{$dir} = undef }
  if ($pid == 0) {
    open(STDERR, ">", "/dev/null");
    $ENV{GIT_TERMINAL_PROMPT} = 0;
    exec("git", "-C", encode_utf8($dir), "remote", "get-url", "origin") or exit 127;
  }
  { local $/; $url = <$git> // "" }
  close $git;
  $url =~ s/\s+\z//;
  my $repo;
  if ($url =~ m{[:/]([^/:]+)/([^/]+?)(?:\.git)?/?\z}) {
    $repo = lc decode_utf8("$1/$2");
  }
  return $repo_cache{$dir} = $repo;
}

sub name_kind {
  my ($name, $pr) = @_;
  return undef unless defined $name && length $name;
  my $n = lc $name;
  return "exact" if $n eq lc $pr->{head};
  my $t = lc $pr->{ticket};
  return undef unless length $t;
  return "ticket_prefix"
    if $n eq $t || (index($n, $t) == 0 && substr($n, length $t, 1) =~ m{^[/\-_ ]$});
  return undef;
}

for my $file (@ARGV) {
  open(my $fh, "<:raw", $file) or do { warn "WARN: cannot read $file: $!\n"; next };
  my (%m, %hit_url, %hit_tkt);
  while (my $line = <$fh>) {
    session_meta(\%m, $line);
    if (keys %hit_url < keys %n_url) {
      $hit_url{$1} = 1 while $line =~ /$url_re/g;
    }
    if (defined $tkt_re && keys %hit_tkt < keys %n_tkt) {
      ticket_hits($tkt_re, $line, \%hit_tkt);
    }
  }
  my $mtime = (stat $fh)[9];
  close $fh;
  next unless defined $mtime;
  my ($agent, $title, $cwd_raw, $last_cwd_raw, $branch_raw) =
    @m{qw(agent title cwd_raw last_cwd_raw branch_raw)};

  (my $sid = $file) =~ s{.*/}{};
  $sid =~ s/\.jsonl\z//;
  $sid = decode_utf8($sid);
  next if length $excl_id && $sid eq $excl_id;
  next if length $exclude && defined $agent && $agent eq $exclude;

  my %branch_text = map { json_str($_) => 1 } keys %{ $m{branches} || {} };
  my $cwd      = defined $cwd_raw      ? json_str($cwd_raw)      : undef;
  my $last_cwd = defined $last_cwd_raw ? json_str($last_cwd_raw) : undef;
  my $git_br   = defined $branch_raw   ? json_str($branch_raw)   : undef;
  my ($repo, $repo_done);

  for my $pr (@prs) {
    my $kind = name_kind($agent, $pr);
    my (@signals, $score);
    $score = 0;
    if ($branch_text{$pr->{head}})                                  { push @signals, "branch"; $score += 4 }
    if (defined $kind)                                              { push @signals, "name";   $score += 4 }
    if ($hit_url{encode_utf8($pr->{url})})                          { push @signals, "pr_url"; $score += 2 }
    if (length $pr->{ticket} && $hit_tkt{encode_utf8(lc $pr->{ticket})}) { push @signals, "ticket"; $score += 1 }
    next unless $score;

    ($repo, $repo_done) = (repo_of($cwd), 1) unless $repo_done;
    my $repo_match = defined $repo ? ($repo eq $pr->{repo} ? JSON::PP::true : JSON::PP::false) : undef;
    my $strong = defined $repo && $repo eq $pr->{repo}
      && ($branch_text{$pr->{head}} || (defined $kind && $kind eq "exact"));

    print $out->encode({
      pr_url    => $pr->{url},
      candidate => {
        session_id   => $sid,
        agent_name   => $agent,
        custom_title => $title,
        cwd          => $cwd,
        last_cwd     => $last_cwd,
        cwd_exists   => (defined $cwd && -d encode_utf8($cwd)) ? JSON::PP::true : JSON::PP::false,
        git_branch   => $git_br,
        repo         => $repo,
        repo_match   => $repo_match,
        name_kind    => $kind,
        score        => $score,
        confidence   => $strong ? "strong" : "weak",
        signals      => \@signals,
        last_active  => $mtime + 0,
      },
    }), "\n";
  }
}
'

if [[ "$PRS_JSON" == "[]" ]]; then
  emit </dev/null
  exit 0
fi

# Buffer the scan so a failed scan prints nothing rather than empty results.
SCAN_OUT="$(mktemp)"
trap 'rm -f "$SCAN_OUT"' EXIT
if ! transcripts_list "$PROJECTS_DIR" "$MAX_AGE_DAYS" \
     | FPS_PRS="$PRS_JSON" FPS_EXCLUDE_NAME="$EXCLUDE_NAME" FPS_EXCLUDE_ID="$EXCLUDE_ID" \
       xargs -0 perl -I"$TRANSCRIPT_SHARED_DIR" -e "$SCAN_PERL" >"$SCAN_OUT"; then
  echo "ERROR: transcript scan failed; results unknown" >&2
  exit 1
fi
emit <"$SCAN_OUT"
