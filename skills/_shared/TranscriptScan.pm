package TranscriptScan;
# Shared helpers for scanning Claude Code JSONL transcripts without fully
# decoding large lines (transcripts run to gigabytes; pure-perl JSON decoding of
# every line is far too slow).
#
# Used by:
#   skills/pr-action-board/scripts/find-pr-sessions.sh
#   skills/resurrect-claude-sessions/scripts/find-ticket-sessions.sh
#
# Load with: perl -I"<skills>/_shared" -MTranscriptScan -e '...'
use strict;
use warnings;
use Encode qw(decode_utf8);
use JSON::PP;
use Exporter 'import';

our @EXPORT_OK = qw(json_str top_value top_object session_meta ticket_re ticket_hits);

# Regex for any of the given ticket keys (byte strings), case-insensitive, not
# followed by a digit (YOU-1 does not match YOU-10). undef if no keys. It has no
# leading boundary on purpose: a leading lookbehind stops perl from scanning
# fast for the key literals (about 6x slower). ticket_hits checks that
# boundary instead.
sub ticket_re {
  my @keys = grep { length } @_;
  return undef unless @keys;
  my $alt = join "|", map { quotemeta } sort { length $b <=> length $a } @keys;
  return qr/($alt)(?![0-9])/i;
}

# Record in %{$_[2]} the lowercased key of every ticket_re ($_[0]) match in the
# byte string $_[1] that starts on a token boundary: at the start, or after a
# char outside [A-Za-z0-9_] (so YOU-1 does not match XYOU-1, and PROJ-1 does
# not match MY_PROJ-1). $_[1] is used in place; its pos() ends up reset.
sub ticket_hits {
  my ($re, undef, $hit) = @_;
  return unless defined $re && defined $_[1];
  while ($_[1] =~ /$re/g) {
    my ($s, $k) = ($-[1], lc $1);
    if ($s && substr($_[1], $s - 1, 1) =~ /[A-Za-z0-9_]/) {
      pos($_[1]) = $s + 1;    # rejected: retry from the next byte
      next;
    }
    $hit->{$k} = 1;
  }
}

# Decode a raw JSON string body (escapes intact) into text. Cached: the same few
# cwd and branch values repeat on every line.
my %dec_cache;
sub json_str {
  my ($raw) = @_;
  return $dec_cache{$raw} //= do {
    my $v = eval { decode_json(qq({"v":"$raw"}))->{v} };
    defined $v ? $v : decode_utf8($raw);
  };
}

# Raw (still JSON-escaped) value of the top-level string field $_[1] (given as
# q("key":")) in the raw JSON line $_[0], without a full decode; undef if absent.
# A raw match of "key":" always starts at a structural quote (quotes inside
# strings are escaped), so the match is top-level iff the bytes after it, with
# string literals stripped, close exactly one more bracket than they open.
# Claude Code writes cwd/gitBranch after the (possibly huge) message body, so
# the walk goes right to left and usually stops at the first hit. Each byte is
# examined once. $_[0] is used in place to avoid copying long lines, and its
# pos() is reset before returning so callers' later /g matches start at 0.
sub top_value {
  my $key = $_[1];
  my ($pos, $seg_end, $net) = (length $_[0], length $_[0], 0);
  while ($pos > 0 && ($pos = rindex($_[0], $key, $pos - 1)) >= 0) {
    my $seg = substr($_[0], $pos, $seg_end - $pos);
    $seg =~ s/"[^"\\]*(?:\\.[^"\\]*)*"//g;
    $net += ($seg =~ tr/}]//) - ($seg =~ tr/{[//);
    $seg_end = $pos;
    next unless $net == 1;
    pos($_[0]) = $pos + length $key;
    my $v = $_[0] =~ /\G([^"\\]*(?:\\.[^"\\]*)*)"/gc ? $1 : undef;
    pos($_[0]) = undef;
    return $v;
  }
  return undef;
}

# Fully decode a line only when it is small enough to be a metadata record.
sub top_object {
  my ($line) = @_;
  return undef if length($line) > 1_048_576;
  my $obj = eval { decode_json($line) };
  return ref $obj eq "HASH" ? $obj : undef;
}

# Update session metadata from one raw line. $m is a hashref collecting:
#   agent        last agentName of an agent-name record
#   title        last customTitle of a custom-title record
#   cwd_raw      first top-level cwd (raw)
#   last_cwd_raw last top-level cwd (raw)
#   branch_raw   last top-level gitBranch (raw)
#   branches     hashref of every raw top-level gitBranch seen
sub session_meta {
  my ($m) = @_;    # line is $_[1], used in place
  if (index($_[1], q("type":"agent-name")) >= 0) {
    my $o = top_object($_[1]);
    $m->{agent} = $o->{agentName}
      if $o && ($o->{type} // "") eq "agent-name" && defined $o->{agentName} && !ref $o->{agentName};
  } elsif (index($_[1], q("type":"custom-title")) >= 0) {
    my $o = top_object($_[1]);
    $m->{title} = $o->{customTitle}
      if $o && ($o->{type} // "") eq "custom-title" && defined $o->{customTitle} && !ref $o->{customTitle};
  }
  if (index($_[1], q("cwd":")) >= 0) {
    my $v = top_value($_[1], q("cwd":"));
    if (defined $v) {
      $m->{cwd_raw} //= $v;
      $m->{last_cwd_raw} = $v;
    }
  }
  if (index($_[1], q("gitBranch":")) >= 0) {
    my $v = top_value($_[1], q("gitBranch":"));
    if (defined $v) {
      $m->{branch_raw} = $v;
      $m->{branches}{$v} = 1;
    }
  }
}

1;
