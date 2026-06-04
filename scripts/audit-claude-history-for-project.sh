#!/usr/bin/env bash
set -euo pipefail

TARGET="$(pwd -P)"
PROJECT_NAME_RE=""
ALL=0
ROOTS=()
ROOT_ARGS=()
CONFIG_DIR_OVERRIDE=""
PREVIEW_LINES=40
SUMMARY_ONLY=0
LATEST=""
SINCE_DAYS=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/audit-claude-history-for-project.sh [options] [target-path]

Defaults to auditing Claude Code history for the current project path.

Options:
  --target <path>             Limit to history files mentioning this project path
  --project-name <regex>      Limit to Claude projects/* directories matching regex
  --project-regex <regex>     Alias for --project-name
  --all                       Audit all JSONL history files under configured roots
  --latest <n>                Audit only the newest n matching JSONL files
  --since-days <n>            Audit only matching JSONL files modified in the last n days
  --summary-only              Print aggregate counts only
  --preview-lines <n>         Max redacted preview lines per file (default: 40)
  --root <dir>                Add an extra Claude config/history root
  --config-dir <dir>          Override the primary Claude config/history root
  -h, --help                  Show this help

Environment:
  CLAUDE_CONFIG_DIR           Claude config root to scan when set
  CLAUDE_HISTORY_ROOTS        Colon-separated additional roots to scan

Examples:
  scripts/audit-claude-history-for-project.sh
  scripts/audit-claude-history-for-project.sh --project-name 'my-project'
  scripts/audit-claude-history-for-project.sh --project-name 'my-project' --latest 20 --summary-only
  scripts/audit-claude-history-for-project.sh --config-dir "$HOME/path-to-claude-config"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
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
    --summary-only)
      SUMMARY_ONLY=1
      shift
      ;;
    --preview-lines)
      PREVIEW_LINES="${2:-40}"
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
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "unknown option: $1"
      usage
      exit 1
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

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

if [[ ! "$PREVIEW_LINES" =~ ^[0-9]+$ ]]; then
  echo "--preview-lines must be a non-negative integer"
  exit 1
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

if [[ "${#ROOTS[@]}" -eq 0 ]]; then
  echo "no Claude config directories found"
  echo "Set CLAUDE_CONFIG_DIR or CLAUDE_HISTORY_ROOTS if your Claude Code history lives outside ~/.claude."
  exit 1
fi

tmp="$(mktemp)"
filtered_tmp="$(mktemp)"
matched_project_dirs_tmp="$(mktemp)"
trap 'rm -f "$tmp" "$filtered_tmp" "$matched_project_dirs_tmp"' EXIT

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
    | tee -a "$matched_project_dirs_tmp" \
    | while IFS= read -r project_dir; do
        find "$project_dir" -type f -name '*.jsonl' -print
      done >> "$tmp"
}

for root in "${ROOTS[@]}"; do
  for scope in projects transcripts; do
    [[ -d "$root/$scope" ]] || continue
    if [[ "$ALL" -eq 1 ]]; then
      find "$root/$scope" -type f -name '*.jsonl' -print >> "$tmp"
    elif [[ -n "$PROJECT_NAME_RE" ]]; then
      [[ "$scope" == "projects" ]] && append_project_name_matches "$root/$scope"
    else
      rg -l --fixed-strings "$TARGET" "$root/$scope" 2>/dev/null >> "$tmp" || true
    fi
  done
done

sort -u "$tmp" -o "$tmp"

filter_candidates() {
  AUDIT_LATEST="$LATEST" AUDIT_SINCE_DAYS="$SINCE_DAYS" perl -e '
    use strict;
    use warnings;

    my @files;
    while (my $path = <>) {
      chomp $path;
      push @files, $path if $path ne "" && -f $path;
    }

    my $latest = $ENV{"AUDIT_LATEST"} // "";
    my $since_days = $ENV{"AUDIT_SINCE_DAYS"} // "";
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
  ' "$tmp" > "$filtered_tmp"
}

filter_candidates

raw_candidate_count="$(wc -l < "$tmp" | tr -d ' ')"
candidate_count="$(wc -l < "$filtered_tmp" | tr -d ' ')"

if [[ ! -s "$filtered_tmp" ]]; then
  if [[ -n "$PROJECT_NAME_RE" ]]; then
    echo "no Claude project history files found for regex: $PROJECT_NAME_RE"
  else
    echo "no Claude history files found for: $TARGET"
  fi
  [[ "$raw_candidate_count" != "0" ]] && echo "raw candidate files before filters: $raw_candidate_count"
  exit 0
fi

echo "target: <PROJECT_ROOT>"
[[ -n "$PROJECT_NAME_RE" ]] && echo "project-name-regex: $PROJECT_NAME_RE"
echo "history roots:"
printf '%s\n' "${ROOTS[@]}" | redact_paths | sed 's/^/  /'
if [[ -n "$PROJECT_NAME_RE" ]]; then
  sort -u "$matched_project_dirs_tmp" -o "$matched_project_dirs_tmp"
  echo "matched project history directories:"
  redact_paths < "$matched_project_dirs_tmp" | sed 's/^/  /'
fi
[[ -n "$SINCE_DAYS" ]] && echo "since-days: $SINCE_DAYS"
[[ -n "$LATEST" ]] && echo "latest: $LATEST"
echo "history files: $candidate_count"
if [[ "$raw_candidate_count" != "$candidate_count" ]]; then
  echo "history files before filters: $raw_candidate_count"
fi
if [[ "$SUMMARY_ONLY" -eq 0 ]]; then
  redact_paths < "$filtered_tmp" | sed 's/^/  /'
fi
echo

export AUDIT_TARGET="$TARGET"
export AUDIT_ENCODED_TARGET="$ENCODED_TARGET"
export AUDIT_PREVIEW_LINES="$PREVIEW_LINES"
export AUDIT_SUMMARY_ONLY="$SUMMARY_ONLY"

perl - "$filtered_tmp" <<'PERL'
use strict;
use warnings;

my ($candidate_file) = @ARGV;
my $target = $ENV{"AUDIT_TARGET"} // "";
my $encoded_target = $ENV{"AUDIT_ENCODED_TARGET"} // "";
my $home = $ENV{"HOME"} // "";
my $preview_limit = $ENV{"AUDIT_PREVIEW_LINES"} // 40;
my $summary_only = ($ENV{"AUDIT_SUMMARY_ONLY"} // "0") eq "1";

sub display_text {
  my ($text) = @_;
  $text =~ s/\Q$target\E/<PROJECT_ROOT>/g if $target ne "";
  $text =~ s/\Q$encoded_target\E/<PROJECT_HISTORY_DIR>/g if $encoded_target ne "";
  $text =~ s/\Q$home\E/~/g if $home ne "";
  return $text;
}

# Secret detection mirrors scripts/redact-claude-history-secrets.sh exactly. One
# pass produces both the per-rule match counts and a redacted copy used for the
# preview, so counting and preview share a single definition (no internal drift,
# and the preview can never print a secret the counter knows about).
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

# Non-secret operational markers, audit-only. Counted but never redacted.
my @marker_rules = (
  [pipelock_blocked => qr/pipelock: blocked|permissionDecisionReason/],
);

# Stable output order for both per-file and summary lines.
my @rule_order = qw(
  github_token github_fine_grained_token openai_key openai_project_key
  anthropic_key stripe_key aws_access_key_id aws_secret_access_key
  google_api_key slack_token jwt database_url_credentials private_key_block
  pipelock_blocked
);

sub scan_line {
  my ($line) = @_;
  my %counts;
  my $had_aws_access_key_id = ($line =~ /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/);

  for my $rule (@replacements) {
    my ($name, $regex, $replacement) = @$rule;
    my $count = 0;
    $line =~ s/$regex/$count++; $replacement/ge;
    $counts{$name} += $count if $count > 0;
  }

  my $sak_a = 0;
  $line =~ s{(\b(?:aws[_-]?secret[_-]?access[_-]?key|aws[_-]?secret[_-]?key)\b[\s"':=\\]{1,8})([A-Za-z0-9/+]{40})(?![A-Za-z0-9/+=])}{
    $sak_a++;
    "$1<AWS_SECRET_ACCESS_KEY>";
  }gei;
  $counts{aws_secret_access_key} += $sak_a if $sak_a > 0;

  if ($had_aws_access_key_id) {
    my $sak_b = 0;
    $line =~ s{(?<![A-Za-z0-9/+])([A-Za-z0-9/+]{40})(?![A-Za-z0-9/+=])}{
      my $cand = $1;
      if ($cand =~ /^[a-f0-9]{40}$/) { $cand; }
      else { $sak_b++; '<AWS_SECRET_ACCESS_KEY>'; }
    }ge;
    $counts{aws_secret_access_key} += $sak_b if $sak_b > 0;
  }

  my $db = 0;
  $line =~ s#\b((?:postgres|postgresql|mysql|mongodb(?:\+srv)?|redis)://)[^/\s:@]+:[^@\s/]+@#$db++; "$1<DB_CREDENTIALS>\@"#ge;
  $counts{database_url_credentials} += $db if $db > 0;

  for my $rule (@marker_rules) {
    my ($name, $regex) = @$rule;
    my $count = 0;
    $count++ while $line =~ /$regex/g;
    $counts{$name} += $count if $count > 0;
  }

  return ($line, \%counts);
}

open my $cfh, "<", $candidate_file or die "open $candidate_file: $!";
my @files = grep { chomp; $_ ne "" } <$cfh>;
close $cfh;

my %total_counts;
my $total_lines = 0;
my $files_seen = 0;
my $files_with_findings = 0;

for my $file (@files) {
  next unless -f $file;
  $files_seen++;

  open my $fh, "<", $file or do {
    warn "cannot read " . display_text($file) . ": $!\n";
    next;
  };

  my %counts;
  my @previews;
  my $lines = 0;
  my $line_no = 0;

  while (my $raw = <$fh>) {
    $line_no++;
    $lines++;
    $total_lines++;

    my ($redacted, $line_counts) = scan_line($raw);
    my $line_matches = 0;
    for my $name (keys %$line_counts) {
      $counts{$name} += $line_counts->{$name};
      $total_counts{$name} += $line_counts->{$name};
      $line_matches += $line_counts->{$name};
    }

    if (!$summary_only && $line_matches > 0 && @previews < $preview_limit) {
      chomp(my $p = display_text($redacted));
      $p = substr($p, 0, 500) . "..." if length($p) > 500;
      push @previews, "$line_no:$p";
    }
  }
  close $fh;

  my $file_matches = 0;
  $file_matches += $_ for values %counts;
  $files_with_findings++ if $file_matches > 0;

  next if $summary_only;

  print "== " . display_text($file) . "\n";
  print "lines: $lines\n";
  for my $name (@rule_order) {
    printf "%-28s %s\n", "$name:", ($counts{$name} // 0);
  }

  print "redacted matching lines:\n";
  print "$_\n" for @previews;
  print "\n";
}

print "summary files_seen=$files_seen files_with_findings=$files_with_findings lines_seen=$total_lines\n";
for my $name (@rule_order) {
  print "summary.$name=" . ($total_counts{$name} // 0) . "\n";
}
PERL
