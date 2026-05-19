#!/usr/bin/env bash
set -euo pipefail

APPLY=0
MODE="redact"
ALL=0
QUIET=0
FROM_HOOK=0
TARGET_SET=0
TARGET="$(pwd -P)"
PREVIEW_LINES=40
HOOK_TRANSCRIPT=""
ROOTS=()
ROOT_ARGS=()
CONFIG_DIR_OVERRIDE=""
PROJECT_NAME_RE=""
LATEST=""
SINCE_DAYS=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/redact-claude-history-secrets.sh [options]

Defaults to dry-run and scans Claude Code history for the current project.

Options:
  --dry-run                 Report findings without changing files (default)
  --apply                   Rewrite matching history files
  --mode redact             Replace matched secret strings with placeholders (default)
  --mode drop-line          Remove entire JSONL lines that contain a match
  --target <path>           Limit to history files mentioning this project path
  --project-name <regex>    Limit to Claude projects/* directories matching regex
  --project-regex <regex>   Alias for --project-name
  --all                     Scan all JSONL history files under configured roots
  --latest <n>              Scan only the newest n matching JSONL files
  --since-days <n>          Scan only matching JSONL files modified in the last n days
  --root <dir>              Add an extra Claude config/history root
  --config-dir <dir>        Override the primary Claude config/history root
  --from-hook               Read Claude hook JSON from stdin and use cwd/transcript_path
  --preview-lines <n>       Max redacted preview lines per file in dry-run (default: 40)
  --quiet                   Print only summary lines
  -h, --help                Show this help

Environment:
  CLAUDE_CONFIG_DIR         Claude config root to scan when set
  CLAUDE_HISTORY_ROOTS      Colon-separated additional roots to scan

Examples:
  scripts/redact-claude-history-secrets.sh
  scripts/redact-claude-history-secrets.sh --apply
  scripts/redact-claude-history-secrets.sh --project-name 'my-project' --dry-run
  scripts/redact-claude-history-secrets.sh --project-name 'my-project' --latest 20 --dry-run
  scripts/redact-claude-history-secrets.sh --apply --mode drop-line
  CLAUDE_HISTORY_ROOTS="$HOME/other-claude-dir" scripts/redact-claude-history-secrets.sh

Claude Code Stop hook example:
  scripts/redact-claude-history-secrets.sh --from-hook --apply --quiet
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      APPLY=0
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --target)
      TARGET="${2:-}"
      TARGET_SET=1
      shift 2
      ;;
    --project-name|--project-regex)
      PROJECT_NAME_RE="${2:-}"
      shift 2
      ;;
    --all)
      ALL=1
      shift
      ;;
    --latest)
      LATEST="${2:-}"
      shift 2
      ;;
    --since-days)
      SINCE_DAYS="${2:-}"
      shift 2
      ;;
    --root)
      ROOT_ARGS+=("${2:-}")
      shift 2
      ;;
    --config-dir)
      CONFIG_DIR_OVERRIDE="${2:-}"
      shift 2
      ;;
    --from-hook)
      FROM_HOOK=1
      shift
      ;;
    --preview-lines)
      PREVIEW_LINES="${2:-40}"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ "$MODE" != "redact" && "$MODE" != "drop-line" ]]; then
  echo "--mode must be either 'redact' or 'drop-line'"
  exit 1
fi

if [[ -n "$PROJECT_NAME_RE" ]]; then
  if ! PROJECT_NAME_RE="$PROJECT_NAME_RE" perl -e 'qr/$ENV{PROJECT_NAME_RE}/' >/dev/null 2>&1; then
    echo "invalid --project-name regex: $PROJECT_NAME_RE"
    exit 1
  fi
fi

if [[ -n "$LATEST" && ! "$LATEST" =~ ^[0-9]+$ ]]; then
  echo "--latest must be a positive integer"
  exit 1
fi

if [[ -n "$LATEST" && "$LATEST" -eq 0 ]]; then
  echo "--latest must be greater than 0"
  exit 1
fi

if [[ -n "$SINCE_DAYS" && ! "$SINCE_DAYS" =~ ^[0-9]+$ ]]; then
  echo "--since-days must be a positive integer"
  exit 1
fi

if [[ -n "$SINCE_DAYS" && "$SINCE_DAYS" -eq 0 ]]; then
  echo "--since-days must be greater than 0"
  exit 1
fi

if [[ "$FROM_HOOK" -eq 1 ]]; then
  hook_json="$(cat || true)"
  if command -v jq >/dev/null 2>&1 && [[ -n "$hook_json" ]]; then
    hook_cwd="$(printf '%s' "$hook_json" | jq -r '.cwd // empty' 2>/dev/null || true)"
    HOOK_TRANSCRIPT="$(printf '%s' "$hook_json" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    if [[ "$TARGET_SET" -eq 0 && -n "$hook_cwd" && -d "$hook_cwd" ]]; then
      TARGET="$hook_cwd"
    fi
  fi
fi

TARGET="$(cd "$TARGET" && pwd -P)"
ENCODED_TARGET="$(printf '%s' "$TARGET" | sed -E 's#[^A-Za-z0-9_-]#-#g')"

add_root() {
  local dir="$1"
  [[ -z "$dir" ]] && return
  case "$dir" in
    "~") dir="$HOME" ;;
    "~/"*) dir="$HOME/${dir#"~/"}" ;;
  esac
  [[ -d "$dir" ]] && ROOTS+=("$(cd "$dir" && pwd -P)")
}

if [[ -n "$CONFIG_DIR_OVERRIDE" ]]; then
  add_root "$CONFIG_DIR_OVERRIDE"
elif [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  add_root "$CLAUDE_CONFIG_DIR"
else
  add_root "$HOME/.claude"
fi

if [[ -n "${CLAUDE_HISTORY_ROOTS:-}" ]]; then
  IFS=':' read -r -a extra_roots <<< "$CLAUDE_HISTORY_ROOTS"
  for dir in "${extra_roots[@]}"; do
    add_root "$dir"
  done
fi

if [[ "${#ROOT_ARGS[@]}" -gt 0 ]]; then
  for dir in "${ROOT_ARGS[@]}"; do
    add_root "$dir"
  done
fi

if [[ "${#ROOTS[@]}" -gt 1 ]]; then
  unique_roots=()
  while IFS= read -r root; do
    unique_roots+=("$root")
  done < <(printf '%s\n' "${ROOTS[@]}" | sort -u)
  ROOTS=("${unique_roots[@]}")
fi

redact_paths() {
  AUDIT_TARGET="$TARGET" AUDIT_ENCODED_TARGET="$ENCODED_TARGET" perl -pe '
    BEGIN {
      $target = $ENV{"AUDIT_TARGET"} // "";
      $encoded_target = $ENV{"AUDIT_ENCODED_TARGET"} // "";
      $home = $ENV{"HOME"} // "";
    }
    if ($target ne "") { s/\Q$target\E/<PROJECT_ROOT>/g; }
    if ($encoded_target ne "") { s/\Q$encoded_target\E/<PROJECT_HISTORY_DIR>/g; }
    if ($home ne "") { s/\Q$home\E/~/g; }
  '
}

candidate_file="$(mktemp)"
filtered_candidate_file="$(mktemp)"
matched_project_dirs_file="$(mktemp)"
trap 'rm -f "$candidate_file" "$filtered_candidate_file" "$matched_project_dirs_file"' EXIT

append_project_name_matches() {
  local projects_dir="$1"
  [[ -d "$projects_dir" ]] || return

  find "$projects_dir" -mindepth 1 -maxdepth 1 -type d -print \
    | PROJECT_NAME_RE="$PROJECT_NAME_RE" perl -ne '
        use strict;
        use warnings;
        my $re = $ENV{"PROJECT_NAME_RE"};
        chomp;
        my $path = $_;
        my $base = $path;
        $base =~ s#^.*/##;
        print "$path\n" if $base =~ /$re/ || $path =~ /$re/;
      ' \
    | tee -a "$matched_project_dirs_file" \
    | while IFS= read -r project_dir; do
        find "$project_dir" -type f -name '*.jsonl' -print
      done >> "$candidate_file"
}

if [[ -n "$HOOK_TRANSCRIPT" && -f "$HOOK_TRANSCRIPT" ]]; then
  printf '%s\n' "$HOOK_TRANSCRIPT" >> "$candidate_file"
fi

if [[ "${#ROOTS[@]}" -gt 0 ]]; then
  for root in "${ROOTS[@]}"; do
    for scope in projects transcripts; do
      [[ -d "$root/$scope" ]] || continue
      if [[ "$ALL" -eq 1 ]]; then
        find "$root/$scope" -type f -name '*.jsonl' -print >> "$candidate_file"
      elif [[ -n "$PROJECT_NAME_RE" ]]; then
        [[ "$scope" == "projects" ]] && append_project_name_matches "$root/$scope"
      else
        rg -l --fixed-strings "$TARGET" "$root/$scope" 2>/dev/null >> "$candidate_file" || true
      fi
    done
  done
fi

sort -u "$candidate_file" -o "$candidate_file"

filter_candidates() {
  REDACT_LATEST="$LATEST" REDACT_SINCE_DAYS="$SINCE_DAYS" perl -e '
    use strict;
    use warnings;

    my @files;
    while (my $path = <>) {
      chomp $path;
      push @files, $path if $path ne "" && -f $path;
    }

    my $latest = $ENV{"REDACT_LATEST"} // "";
    my $since_days = $ENV{"REDACT_SINCE_DAYS"} // "";
    my $cutoff = $since_days ne "" ? time - ($since_days * 86400) : 0;

    my @selected = @files;
    if ($since_days ne "") {
      @selected = grep { ((stat($_))[9] || 0) >= $cutoff } @selected;
    }

    @selected = sort {
      (((stat($b))[9] || 0) <=> ((stat($a))[9] || 0)) || ($a cmp $b)
    } @selected;

    if ($latest ne "" && @selected > $latest) {
      @selected = @selected[0 .. $latest - 1];
    }

    print "$_\n" for @selected;
  ' "$candidate_file" > "$filtered_candidate_file"
}

filter_candidates

raw_candidate_count="$(wc -l < "$candidate_file" | tr -d ' ')"
candidate_count="$(wc -l < "$filtered_candidate_file" | tr -d ' ')"

if [[ ! -s "$filtered_candidate_file" ]]; then
  [[ "$QUIET" -eq 1 ]] || echo "no matching Claude history files found"
  [[ "$QUIET" -eq 1 || "$raw_candidate_count" == "0" ]] || echo "raw candidate files before filters: $raw_candidate_count"
  exit 0
fi

export REDACT_APPLY="$APPLY"
export REDACT_MODE="$MODE"
export REDACT_QUIET="$QUIET"
export REDACT_PREVIEW_LINES="$PREVIEW_LINES"
export REDACT_TARGET="$TARGET"
export REDACT_ENCODED_TARGET="$ENCODED_TARGET"

if [[ "$QUIET" -eq 0 ]]; then
  echo "history roots:"
  printf '%s\n' "${ROOTS[@]}" | redact_paths | sed 's/^/  /'
  if [[ -n "$PROJECT_NAME_RE" ]]; then
    sort -u "$matched_project_dirs_file" -o "$matched_project_dirs_file"
    echo "matched project history directories:"
    redact_paths < "$matched_project_dirs_file" | sed 's/^/  /'
  fi
  [[ -n "$SINCE_DAYS" ]] && echo "since-days: $SINCE_DAYS"
  [[ -n "$LATEST" ]] && echo "latest: $LATEST"
  echo "history files: $candidate_count"
  if [[ "$raw_candidate_count" != "$candidate_count" ]]; then
    echo "history files before filters: $raw_candidate_count"
  fi
fi

perl - "$filtered_candidate_file" <<'PERL'
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Copy qw(move);
use File::Temp qw(tempfile);

my ($candidate_file) = @ARGV;
my $apply = $ENV{REDACT_APPLY} eq '1';
my $mode = $ENV{REDACT_MODE};
my $quiet = $ENV{REDACT_QUIET} eq '1';
my $preview_limit = $ENV{REDACT_PREVIEW_LINES} || 40;
my $target = $ENV{REDACT_TARGET} // '';
my $encoded_target = $ENV{REDACT_ENCODED_TARGET} // '';
my $home = $ENV{HOME} // '';

sub display_path {
  my ($path) = @_;
  $path =~ s/\Q$target\E/<PROJECT_ROOT>/g if $target ne '';
  $path =~ s/\Q$encoded_target\E/<PROJECT_HISTORY_DIR>/g if $encoded_target ne '';
  $path =~ s/\Q$home\E/~/g if $home ne '';
  return $path;
}

sub preview_text {
  my ($line) = @_;
  chomp $line;
  $line =~ s/\Q$target\E/<PROJECT_ROOT>/g if $target ne '';
  $line =~ s/\Q$encoded_target\E/<PROJECT_HISTORY_DIR>/g if $encoded_target ne '';
  $line =~ s/\Q$home\E/~/g if $home ne '';
  $line =~ s/ghp_[A-Za-z0-9_]{20,}/<GITHUB_TOKEN>/g;
  $line =~ s/github_pat_[A-Za-z0-9_]{20,}/<GITHUB_FINE_GRAINED_TOKEN>/g;
  $line =~ s/gh[ousr]_[A-Za-z0-9_]{20,}/<GITHUB_TOKEN>/g;
  $line =~ s/sk-ant-api03-[A-Za-z0-9_-]{20,}/<ANTHROPIC_KEY>/g;
  $line =~ s/sk-proj-[A-Za-z0-9_-]{20,}/<OPENAI_KEY>/g;
  $line =~ s/\bsk-[A-Za-z0-9]{32,}\b/<OPENAI_KEY>/g;
  $line =~ s/\b[rs]k_(live|test)_[A-Za-z0-9]{20,}\b/<STRIPE_KEY>/g;
  my $had_aws_access_key_id = ($line =~ /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/);
  $line =~ s/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/<AWS_ACCESS_KEY_ID>/g;
  $line =~ s/\bAIza[0-9A-Za-z_-]{35}\b/<GOOGLE_API_KEY>/g;
  $line =~ s/\bxox[baprs]-[0-9A-Za-z-]{20,}\b/<SLACK_TOKEN>/g;
  $line =~ s/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/<JWT>/g;
  $line =~ s{(\b(?:aws[_-]?secret[_-]?access[_-]?key|aws[_-]?secret[_-]?key)\b[\s"':=\\]{1,8})([A-Za-z0-9/+]{40})(?![A-Za-z0-9/+=])}{$1<AWS_SECRET_ACCESS_KEY>}gi;
  if ($had_aws_access_key_id) {
    $line =~ s{(?<![A-Za-z0-9/+])([A-Za-z0-9/+]{40})(?![A-Za-z0-9/+=])}{
      my $candidate = $1;
      $candidate =~ /^[a-f0-9]{40}$/ ? $candidate : '<AWS_SECRET_ACCESS_KEY>';
    }ge;
  }
  $line =~ s#\b((?:postgres|postgresql|mysql|mongodb(?:\+srv)?|redis)://)[^/\s:@]+:[^@\s/]+@#$1<DB_CREDENTIALS>@#g;
  $line =~ s/-----BEGIN (?:RSA |EC |OPENSSH |DSA |)?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH |DSA |)?PRIVATE KEY-----/<PRIVATE_KEY_BLOCK>/g;
  return length($line) > 360 ? substr($line, 0, 360) . '...' : $line;
}

sub redact_line {
  my ($line) = @_;
  my %rules;
  my $changed = 0;

  my $had_aws_access_key_id = ($line =~ /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/);

  my @replacements = (
    [github_fine_grained_token => qr/\bgithub_pat_[A-Za-z0-9_]{20,}\b/, '<GITHUB_FINE_GRAINED_TOKEN>'],
    [github_token => qr/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b/, '<GITHUB_TOKEN>'],
    [anthropic_key => qr/\bsk-ant-api03-[A-Za-z0-9_-]{20,}\b/, '<ANTHROPIC_KEY>'],
    [openai_project_key => qr/\bsk-proj-[A-Za-z0-9_-]{20,}\b/, '<OPENAI_KEY>'],
    [openai_key => qr/\bsk-[A-Za-z0-9]{32,}\b/, '<OPENAI_KEY>'],
    [stripe_key => qr/\b[rs]k_(?:live|test)_[A-Za-z0-9]{20,}\b/, '<STRIPE_KEY>'],
    [aws_access_key_id => qr/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, '<AWS_ACCESS_KEY_ID>'],
    [google_api_key => qr/\bAIza[0-9A-Za-z_-]{35}\b/, '<GOOGLE_API_KEY>'],
    [slack_token => qr/\bxox[baprs]-[0-9A-Za-z-]{20,}\b/, '<SLACK_TOKEN>'],
    [jwt => qr/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/, '<JWT>'],
    [private_key_block => qr/-----BEGIN (?:RSA |EC |OPENSSH |DSA |)?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH |DSA |)?PRIVATE KEY-----/, '<PRIVATE_KEY_BLOCK>'],
  );

  for my $rule (@replacements) {
    my ($name, $regex, $replacement) = @$rule;
    my $count = 0;
    $line =~ s/$regex/$count++; $replacement/ge;
    if ($count > 0) {
      $rules{$name} += $count;
      $changed += $count;
    }
  }

  my $sak_a_count = 0;
  $line =~ s{(\b(?:aws[_-]?secret[_-]?access[_-]?key|aws[_-]?secret[_-]?key)\b[\s"':=\\]{1,8})([A-Za-z0-9/+]{40})(?![A-Za-z0-9/+=])}{
    $sak_a_count++;
    "$1<AWS_SECRET_ACCESS_KEY>";
  }gei;
  if ($sak_a_count > 0) {
    $rules{aws_secret_access_key} += $sak_a_count;
    $changed += $sak_a_count;
  }

  if ($had_aws_access_key_id) {
    my $sak_b_count = 0;
    $line =~ s{(?<![A-Za-z0-9/+])([A-Za-z0-9/+]{40})(?![A-Za-z0-9/+=])}{
      my $candidate = $1;
      if ($candidate =~ /^[a-f0-9]{40}$/) {
        $candidate;
      } else {
        $sak_b_count++;
        '<AWS_SECRET_ACCESS_KEY>';
      }
    }ge;
    if ($sak_b_count > 0) {
      $rules{aws_secret_access_key} += $sak_b_count;
      $changed += $sak_b_count;
    }
  }

  my $db_count = 0;
  $line =~ s#\b((?:postgres|postgresql|mysql|mongodb(?:\+srv)?|redis)://)[^/\s:@]+:[^@\s/]+@#$db_count++; "$1<DB_CREDENTIALS>\@"#ge;
  if ($db_count > 0) {
    $rules{database_url_credentials} += $db_count;
    $changed += $db_count;
  }

  return ($line, $changed, \%rules);
}

open my $cfh, '<', $candidate_file or die "open $candidate_file: $!";
my @files = grep { chomp; length $_ } <$cfh>;
close $cfh;

my $total_files = 0;
my $changed_files = 0;
my $total_lines_seen = 0;
my $total_lines_changed = 0;
my $total_matches = 0;
my %total_rules;

print "mode: " . ($apply ? "apply" : "dry-run") . " ($mode)\n" unless $quiet;

for my $file (@files) {
  next unless -f $file;
  $total_files++;

  open my $in, '<', $file or do {
    warn "cannot read " . display_path($file) . ": $!\n";
    next;
  };

  my @out;
  my @previews;
  my %file_rules;
  my $line_no = 0;
  my $lines_changed = 0;
  my $matches = 0;

  while (my $line = <$in>) {
    $line_no++;
    $total_lines_seen++;
    my ($redacted, $count, $rules) = redact_line($line);
    if ($count > 0) {
      $lines_changed++;
      $matches += $count;
      for my $name (keys %$rules) {
        $file_rules{$name} += $rules->{$name};
        $total_rules{$name} += $rules->{$name};
      }
      if (@previews < $preview_limit) {
        push @previews, sprintf("%d:%s", $line_no, preview_text($redacted));
      }
      push @out, $redacted if $mode eq 'redact';
    } else {
      push @out, $line;
    }
  }
  close $in;

  $total_lines_changed += $lines_changed;
  $total_matches += $matches;

  next if $matches == 0;
  $changed_files++;

  unless ($quiet) {
    print "== " . display_path($file) . "\n";
    print "matches=$matches lines_changed=$lines_changed\n";
    for my $name (sort keys %file_rules) {
      print "  $name=$file_rules{$name}\n";
    }
    if (!$apply && @previews) {
      print "redacted preview:\n";
      print "  $_\n" for @previews;
    }
    print "\n";
  }

  if ($apply) {
    my ($tmpfh, $tmpfile) = tempfile(".redact-history.XXXXXX", DIR => dirname($file), UNLINK => 0);
    print {$tmpfh} @out;
    close $tmpfh or die "close temp file: $!";
    my $mode_bits = (stat($file))[2] & 07777;
    chmod $mode_bits, $tmpfile;
    move($tmpfile, $file) or die "replace " . display_path($file) . ": $!";
  }
}

print "summary files_seen=$total_files files_changed=$changed_files lines_seen=$total_lines_seen lines_changed=$total_lines_changed matches=$total_matches\n";
for my $name (sort keys %total_rules) {
  print "summary.rule.$name=$total_rules{$name}\n";
}
PERL
