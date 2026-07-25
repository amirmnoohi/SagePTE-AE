#!/usr/bin/env bash
#
# ==============================================================================
#  SagePTE Artifact — Terminal Presentation Layer
# ==============================================================================
#
#  A small, dependency-free library that gives every script in this artifact a
#  single, consistent look. It is sourced, never executed:
#
#      source "${REPO_ROOT}/Lib/ui.sh"
#      ui::init
#
#  Design rules
#  ------------
#  1. Degrade gracefully. Colour is emitted only to a terminal that supports it;
#     box-drawing falls back to ASCII when the locale is not UTF-8. Piping any
#     script's output to a file therefore yields clean, greppable text.
#  2. Honour the environment. NO_COLOR (https://no-color.org/) and TERM=dumb are
#     respected, as is an explicit `ui::set_color off`.
#  3. Separate streams. Durable output (headings, results) goes to stdout so it
#     survives `| tee`; transient progress (the live "waiting…" line, which uses
#     carriage returns) goes to stderr and is emitted only when stderr is a TTY.
#     Redirecting either stream never produces control-character noise.
#  4. Never fail the caller. No function here returns non-zero for a formatting
#     concern; presentation must not break a capture run.
#
#  Naming: all public functions are prefixed `ui::`; internal state uses the
#  `_UI_` prefix and should not be relied upon outside this file.
#
# ==============================================================================

# Guard against double-sourcing (harmless, but keeps `set -u` state predictable).
[[ -n "${_UI_SOURCED:-}" ]] && return 0
_UI_SOURCED=1

# ------------------------------------------------------------------------------
# Internal state. Populated by ui::init; do not set directly.
# ------------------------------------------------------------------------------
_UI_COLOR=0          # 1 when ANSI colour is enabled
_UI_UNICODE=0        # 1 when box-drawing/glyph characters are safe to emit
_UI_WIDTH=78         # rendering width in columns
_UI_STEP=0           # current step number, advanced by ui::step
_UI_STEPS=0          # total number of steps, set by ui::set_steps
_UI_WAIT_LABEL=""    # label of the in-flight ui::wait_* progress line
_UI_WAIT_START=0     # epoch seconds when the current wait began
_UI_WAIT_LAST=0      # last time a non-TTY progress line was printed
_UI_WAIT_ACTIVE=0    # 1 while a progress line is on screen
_UI_WAIT_TEXT=""     # last label rendered, so ui::wait_sleep can redraw it
_UI_SPIN_I=0         # spinner frame, advanced per redraw rather than per second
_UI_LABEL_WIDTH=18   # column width for ui::field labels
_UI_COMPACT=0        # 1 when running nested inside another script's output

#######################################
# Initialise the presentation layer: detect terminal capabilities and define
# the colour and glyph tables. Safe to call more than once.
# Globals:
#   Sets _UI_COLOR, _UI_UNICODE, _UI_WIDTH, and the C_*/G_* tables.
#   Reads NO_COLOR, TERM, COLUMNS, LC_ALL, LC_CTYPE, LANG.
# Arguments:
#   None.
# Outputs:
#   None.
#######################################
ui::init() {
  # --- colour -----------------------------------------------------------------
  # Enabled only for a real terminal that is not explicitly opted out.
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    _UI_COLOR=1
  else
    _UI_COLOR=0
  fi

  # --- unicode ----------------------------------------------------------------
  # Box-drawing is only safe when the active locale is UTF-8; otherwise the
  # characters render as mojibake, which looks far worse than plain ASCII.
  local charset="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ "${charset}" == *[Uu][Tt][Ff]-8* || "${charset}" == *[Uu][Tt][Ff]8* ]]; then
    _UI_UNICODE=1
  else
    _UI_UNICODE=0
  fi

  # --- width ------------------------------------------------------------------
  # Follow the terminal, but stay inside sane bounds so that output is readable
  # both in a narrow pane and on an ultrawide monitor.
  local cols=""
  if [[ -t 1 ]]; then
    cols="$(tput cols 2>/dev/null || echo "${COLUMNS:-80}")"
  fi
  [[ "${cols}" =~ ^[0-9]+$ ]] || cols=80
  (( cols > 100 )) && cols=100
  (( cols < 48 )) && cols=48
  _UI_WIDTH=$(( cols - 2 ))

  ui::_define_palette
  ui::_define_glyphs
}

#######################################
# Force colour on or off, overriding auto-detection (for a --no-color flag).
# Arguments:
#   $1 — "on" or "off".
#######################################
ui::set_color() {
  case "${1:-}" in
    on)  _UI_COLOR=1 ;;
    off) _UI_COLOR=0 ;;
  esac
  ui::_define_palette
}

#######################################
# Declare how many steps the run has, so ui::step can render "N/TOTAL".
# Arguments:
#   $1 — total number of steps.
#######################################
ui::set_steps() {
  _UI_STEPS="${1:-0}"
  _UI_STEP=0
}

#######################################
# Enter or leave compact mode.
#
# A script invoked from inside another script's output (a page-table dumper
# nested in a tracer run) must not print a second set of banners, rules and numbered
# sections: two nested programs' worth of chrome is unreadable. In compact mode
# the structural elements collapse to nothing and the closing banner shrinks to
# a single line, leaving only the status lines that carry information.
# Arguments:
#   $1 — "on" or "off".
#######################################
ui::set_compact() {
  case "${1:-}" in
    on)  _UI_COMPACT=1 ;;
    off) _UI_COMPACT=0 ;;
  esac
}

# ------------------------------------------------------------------------------
# Capability tables
# ------------------------------------------------------------------------------

#######################################
# Define the colour escape table. All names are plain variables so they can be
# interpolated directly into strings; every one is empty when colour is off,
# which makes the call sites identical in both modes.
#######################################
ui::_define_palette() {
  if (( _UI_COLOR )); then
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';    C_DIM=$'\033[2m'
    C_RED=$'\033[31m';   C_GREEN=$'\033[32m';  C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m';  C_CYAN=$'\033[36m';   C_GREY=$'\033[90m'
  else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED='';   C_GREEN=''; C_YELLOW=''
    C_BLUE='';  C_CYAN='';  C_GREY=''
  fi
}

#######################################
# Define the glyph table (box drawing, status marks, spinner frames), with an
# ASCII fallback for non-UTF-8 locales.
#######################################
ui::_define_glyphs() {
  if (( _UI_UNICODE )); then
    G_TL='╭'; G_TR='╮'; G_BL='╰'; G_BR='╯'; G_H='─'; G_V='│'
    G_OK='✔'; G_FAIL='✘'; G_WARN='▲'; G_INFO='•'; G_ARROW='→'; G_DOT='·'
    G_BAR_FULL='█'; G_BAR_EMPTY='░'
    _UI_SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  else
    G_TL='+'; G_TR='+'; G_BL='+'; G_BR='+'; G_H='-'; G_V='|'
    G_OK='[OK]'; G_FAIL='[!!]'; G_WARN='[!]'; G_INFO='*'; G_ARROW='->'; G_DOT='-'
    G_BAR_FULL='#'; G_BAR_EMPTY='.'
    _UI_SPIN=('|' '/' '-' '\')
  fi
}

#######################################
# Repeat a string N times (used for rules and padding).
# Arguments:
#   $1 — the string to repeat; $2 — repeat count.
# Outputs:
#   The repeated string on stdout, without a trailing newline.
#######################################
ui::_repeat() {
  local ch="$1" n="${2:-0}" out=''
  (( n <= 0 )) && return 0
  # printf pads with spaces, then substitution turns them into the glyph; this
  # is far faster than looping for typical widths.
  printf -v out '%*s' "$n" ''
  printf '%s' "${out// /$ch}"
}

# ------------------------------------------------------------------------------
# Structural output
# ------------------------------------------------------------------------------

#######################################
# Emit trailing spaces so that TEXT occupies WIDTH display columns.
#
# printf's "%-*s" pads to a width counted in *bytes*, which silently breaks box
# alignment as soon as a string contains a multi-byte character ("·" is two
# bytes but one column). Bash's ${#var} counts characters in a UTF-8 locale, so
# padding is computed from that instead.
# Arguments:
#   $1 — text; $2 — target width in columns.
# Outputs:
#   The padding spaces on stdout (the caller prints the text itself).
#######################################
ui::_pad_to() {
  local text="$1"
  local width="${2:-0}"
  local pad=$(( width - ${#text} ))
  (( pad > 0 )) && ui::_repeat ' ' "${pad}"
  return 0   # a fully-occupied line is not an error
}

#######################################
# Render one framed line of a banner: "│  <text><padding>│".
# Arguments:
#   $1 — border colour; $2 — text style; $3 — text; $4 — inner width.
#######################################
ui::_banner_line() {
  local border="$1" style="$2" text="$3" inner="$4"
  printf '%s%s%s  %s%s%s%s%s%s%s\n' \
    "${border}" "${G_V}" "${C_RESET}" \
    "${style}" "${text}" "${C_RESET}" \
    "$(ui::_pad_to "${text}" $(( inner - 2 )))" \
    "${border}" "${G_V}" "${C_RESET}"
}

#######################################
# Render the top-of-run banner.
# Arguments:
#   $1 — title; $2 — optional subtitle rendered beneath it.
# Outputs:
#   A boxed heading on stdout.
#######################################
ui::banner() {
  (( _UI_COMPACT )) && return 0
  local title="$1" subtitle="${2:-}" inner=$(( _UI_WIDTH - 2 ))
  echo
  printf '%s%s%s%s%s\n' "${C_BLUE}" "${G_TL}" "$(ui::_repeat "${G_H}" "${inner}")" "${G_TR}" "${C_RESET}"
  ui::_banner_line "${C_BLUE}" "${C_BOLD}" "${title}" "${inner}"
  [[ -n "${subtitle}" ]] &&
    ui::_banner_line "${C_BLUE}" "${C_DIM}" "${subtitle}" "${inner}"
  printf '%s%s%s%s%s\n' "${C_BLUE}" "${G_BL}" "$(ui::_repeat "${G_H}" "${inner}")" "${G_BR}" "${C_RESET}"
  echo
}

#######################################
# Render the closing result banner, colour-coded by outcome.
# Arguments:
#   $1 — outcome: "ok" or "fail"; $2 — title.
# Outputs:
#   A boxed, colour-coded result heading on stdout.
#######################################
ui::result_banner() {
  local outcome="$1" title="$2" inner=$(( _UI_WIDTH - 2 )) colour mark
  case "${outcome}" in
    ok)   colour="${C_GREEN}"; mark="${G_OK}" ;;
    *)    colour="${C_RED}";   mark="${G_FAIL}" ;;
  esac

  # Nested inside another script: one line, not a box.
  if (( _UI_COMPACT )); then
    printf '  %s%s %s%s\n' "${colour}${C_BOLD}" "${mark}" "${title}" "${C_RESET}"
    return 0
  fi
  # Glyph width differs between the unicode and ASCII tables, so the line is
  # padded from its rendered length rather than a fixed offset.
  local text="${mark}  ${title}"
  echo
  printf '%s%s%s%s%s\n' "${colour}" "${G_TL}" "$(ui::_repeat "${G_H}" "${inner}")" "${G_TR}" "${C_RESET}"
  ui::_banner_line "${colour}" "${colour}${C_BOLD}" "${text}" "${inner}"
  printf '%s%s%s%s%s\n' "${colour}" "${G_BL}" "$(ui::_repeat "${G_H}" "${inner}")" "${G_BR}" "${C_RESET}"
  echo
}

#######################################
# Begin a numbered step. Advances the internal counter.
# Globals:
#   Reads/increments _UI_STEP; reads _UI_STEPS.
# Arguments:
#   $1 — step title.
# Outputs:
#   A labelled horizontal rule on stdout.
#######################################
ui::step() {
  (( _UI_COMPACT )) && return 0
  local title="$1" label
  _UI_STEP=$(( _UI_STEP + 1 ))
  if (( _UI_STEPS > 0 )); then
    label=" ${_UI_STEP}/${_UI_STEPS} ${G_DOT} ${title} "
  else
    label=" ${title} "
  fi
  local fill=$(( _UI_WIDTH - ${#label} - 4 ))
  (( fill < 0 )) && fill=0
  echo
  printf '%s%s%s%s%s%s%s\n' \
    "${C_CYAN}" "$(ui::_repeat "${G_H}" 4)" "${C_RESET}${C_BOLD}" "${label}" \
    "${C_RESET}${C_CYAN}" "$(ui::_repeat "${G_H}" "${fill}")" "${C_RESET}"
}

#######################################
# Print a plain horizontal rule.
#######################################
ui::rule() {
  (( _UI_COMPACT )) && return 0
  printf '%s%s%s\n' "${C_GREY}" "$(ui::_repeat "${G_H}" "${_UI_WIDTH}")" "${C_RESET}"
}

#######################################
# Print an aligned "label   value" pair, the standard way to show a setting or
# a result in this artifact.
# Arguments:
#   $1 — label; $2 — value (printed verbatim, never truncated: paths matter).
#######################################
ui::field() {
  printf '  %s%-*s%s %s\n' \
    "${C_DIM}" "${_UI_LABEL_WIDTH}" "$1" "${C_RESET}" "${2:-}"
}

#######################################
# Print a continuation line aligned under the value column of ui::field.
# Arguments:
#   $1 — text.
#######################################
ui::field_cont() {
  printf '  %-*s %s%s%s\n' "${_UI_LABEL_WIDTH}" '' "${C_DIM}" "$1" "${C_RESET}"
}

#######################################
# Print a blank line (kept as a function so spacing stays consistent).
#######################################
ui::blank() { echo; }

# ------------------------------------------------------------------------------
# Status messages
# ------------------------------------------------------------------------------

# Each takes a single message argument and prints one marked line.
ui::ok()   { printf '  %s%s%s %s\n' "${C_GREEN}"  "${G_OK}"    "${C_RESET}" "$1"; }
ui::info() { printf '  %s%s%s %s\n' "${C_BLUE}"   "${G_INFO}"  "${C_RESET}" "$1"; }
ui::note() { printf '  %s%s %s%s\n' "${C_DIM}"    "${G_ARROW}" "$1" "${C_RESET}"; }
ui::warn() { printf '  %s%s%s %s\n' "${C_YELLOW}" "${G_WARN}"  "${C_RESET}" "$1" >&2; }
ui::fail() { printf '  %s%s%s %s\n' "${C_RED}"    "${G_FAIL}"  "${C_RESET}" "$1" >&2; }

#######################################
# Render a command the user is expected to run, indented and highlighted.
# Arguments:
#   $* — the command line.
#######################################
ui::command() {
  printf '      %s%s%s\n' "${C_BOLD}${C_CYAN}" "$*" "${C_RESET}"
}

#######################################
# Report a fatal error and terminate. Every line of the message is printed;
# subsequent lines are indented as hints, so callers can attach remediation
# advice to the failure that caused it.
# Arguments:
#   $1  — error message.
#   $2… — optional hint lines.
# Returns:
#   Never; exits with ${UI_EXIT_CODE:-1}.
#######################################
ui::die() {
  local msg="$1"; shift
  echo >&2
  printf '  %s%s %s%s\n' "${C_RED}${C_BOLD}" "${G_FAIL}" "${msg}" "${C_RESET}" >&2
  local hint
  for hint in "$@"; do
    printf '     %s%s%s\n' "${C_DIM}" "${hint}" "${C_RESET}" >&2
  done
  echo >&2
  exit "${UI_EXIT_CODE:-1}"
}

# ------------------------------------------------------------------------------
# Progress reporting for long waits
# ------------------------------------------------------------------------------
#
# These three functions bracket a polling loop:
#
#     ui::wait_begin "waiting for the dataset to load"
#     while ...; do sleep 1; ui::wait_tick; done
#     ui::wait_end "ready"
#
# On a TTY this renders a single self-updating line with a spinner and elapsed
# time. Off a TTY (a log file, CI) it prints a short progress note at a fixed
# interval instead, so logs stay readable and free of control characters.

#######################################
# Start a progress line.
# Arguments:
#   $1 — label describing what is being waited for.
#######################################
ui::wait_begin() {
  _UI_WAIT_LABEL="$1"
  _UI_WAIT_START=${SECONDS}
  _UI_WAIT_LAST=${SECONDS}
  _UI_WAIT_ACTIVE=1
  if [[ ! -t 2 ]]; then
    printf '  %s %s...\n' "${G_INFO}" "${_UI_WAIT_LABEL}"
  fi
}

#######################################
# Advance the progress line. Call once per poll iteration; cheap enough to call
# every loop pass.
#######################################
ui::wait_tick() {
  (( _UI_WAIT_ACTIVE )) || return 0
  # An argument replaces the label for this redraw, which lets a caller report
  # live progress ("12.4GB / ~135GB (9%)") instead of a static message.
  local label="${1:-${_UI_WAIT_LABEL}}"
  _UI_WAIT_TEXT="${label}"
  local elapsed=$(( SECONDS - _UI_WAIT_START ))
  if [[ -t 2 ]]; then
    _UI_SPIN_I=$(( _UI_SPIN_I + 1 ))
    local frame="${_UI_SPIN[$(( _UI_SPIN_I % ${#_UI_SPIN[@]} ))]}"
    printf '\r  %s%s%s %s %s%s%s\033[K' \
      "${C_CYAN}" "${frame}" "${C_RESET}" "${label}" \
      "${C_DIM}" "$(ui::duration "${elapsed}")" "${C_RESET}" >&2
  else
    # Not a terminal: emit a line every 30s rather than rewriting in place.
    if (( SECONDS - _UI_WAIT_LAST >= 30 )); then
      _UI_WAIT_LAST=${SECONDS}
      printf '  %s %s (%s)\n' "${G_DOT}" "${label}" "$(ui::duration "${elapsed}")"
    fi
  fi
}

#######################################
# Sleep, keeping the progress line animated while doing so.
#
# Callers poll things that are expensive to ask about — a file size over SSH, a
# directory total — so they cannot poll at the frame rate. This decouples the
# two: the caller sleeps for as long as it wants between polls, and the spinner
# is redrawn many times inside that sleep. Off a TTY there is nothing to
# animate, so it is a plain sleep.
# Arguments:
#   $1 — seconds to sleep (may be fractional).
#######################################
ui::wait_sleep() {
  local total="${1:-1}"
  if [[ ! -t 2 ]] || (( ! _UI_WAIT_ACTIVE )); then
    sleep "${total}"
    return 0
  fi
  # Integer arithmetic only: twelve frames a second, which is smooth to the eye
  # and costs nothing. Callers pass whole seconds.
  local frames=$(( ${total%%.*} * 12 )) i
  (( frames < 1 )) && frames=12
  for (( i = 0; i < frames; i++ )); do
    sleep 0.08
    ui::wait_tick "${_UI_WAIT_TEXT}"
  done
  return 0
}

#######################################
# Render a compact progress bar.
# Arguments:
#   $1 — percentage complete (clamped to 0..100); $2 — width in cells (default 16).
# Outputs:
#   The bar on stdout, without surrounding brackets or colour.
#######################################
ui::bar() {
  local pct="${1:-0}" width="${2:-16}" filled
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  filled=$(( pct * width / 100 ))
  printf '%s%s' \
    "$(ui::_repeat "${G_BAR_FULL}" "${filled}")" \
    "$(ui::_repeat "${G_BAR_EMPTY}" $(( width - filled )))"
}

#######################################
# Format a byte count as a human-readable string (1.3GB, 940MB, ...).
# Arguments:
#   $1 — bytes.
# Outputs:
#   The formatted size on stdout.
#######################################
ui::bytes() {
  numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"
}

#######################################
# Render a progress label: a bar, how far through, and an estimate.
#
# Intended as the argument to ui::wait_tick, for the cases where the total is
# genuinely known. Where it is not — a trace that runs until a reference count
# no file size predicts — pass a plain description instead and let the elapsed
# time speak, rather than inventing a completion figure.
# Arguments:
#   $1 — verb, e.g. "uploading";
#   $2 — units done; $3 — units total;
#   $4 — units per second, 0 or empty when not yet known;
#   $5 — optional formatter: "bytes" (default) or "plain".
# Outputs:
#   The label on stdout.
#######################################
ui::progress() {
  local verb="$1" done="${2:-0}" total="${3:-0}" rate="${4:-0}" fmt="${5:-bytes}"
  local pct=0 eta='' render
  (( total > 0 )) && pct=$(( done * 100 / total ))
  (( pct > 100 )) && pct=100

  if [[ "${fmt}" == bytes ]]; then
    render=ui::bytes
  else
    render=ui::number
  fi

  if (( rate > 0 && total > done )); then
    eta="  ${C_DIM}ETA $(ui::duration $(( (total - done) / rate )))${C_RESET}"
  fi
  printf '%s %3d%%  %s  %s / %s%s' \
    "${verb}" "${pct}" "$(ui::bar "${pct}" 20)" \
    "$(${render} "${done}")" "$(${render} "${total}")" "${eta}"
}

#######################################
# Finish the progress line, replacing it with a final success message.
# Arguments:
#   $1 — completion message. The elapsed time is appended automatically.
#######################################
ui::wait_end() {
  (( _UI_WAIT_ACTIVE )) || return 0
  local elapsed=$(( SECONDS - _UI_WAIT_START ))
  [[ -t 2 ]] && printf '\r\033[K' >&2
  _UI_WAIT_ACTIVE=0
  ui::ok "$1 ${C_DIM}($(ui::duration "${elapsed}"))${C_RESET}"
}

#######################################
# Abandon the progress line without a success message (used on error paths so
# the failure is not printed on top of a half-drawn spinner).
#######################################
ui::wait_abort() {
  (( _UI_WAIT_ACTIVE )) || return 0
  [[ -t 2 ]] && printf '\r\033[K' >&2
  _UI_WAIT_ACTIVE=0
}

# ------------------------------------------------------------------------------
# Formatting helpers
# ------------------------------------------------------------------------------

#######################################
# Format a duration in seconds as a compact human-readable string.
# Arguments:
#   $1 — whole seconds.
# Outputs:
#   e.g. "45s", "3m 07s", "1h 02m 33s" on stdout.
#######################################
ui::duration() {
  local total="${1:-0}" h m s
  h=$(( total / 3600 )); m=$(( (total % 3600) / 60 )); s=$(( total % 60 ))
  if   (( h > 0 )); then printf '%dh %02dm %02ds' "${h}" "${m}" "${s}"
  elif (( m > 0 )); then printf '%dm %02ds' "${m}" "${s}"
  else                   printf '%ds' "${s}"
  fi
}

#######################################
# Human-readable size of a file or directory.
# Arguments:
#   $1 — path.
# Outputs:
#   e.g. "11.7G", or "n/a" when the path does not exist.
#######################################
ui::size_of() {
  local path="$1"
  [[ -e "${path}" ]] || { printf 'n/a'; return 0; }
  du -sh "${path}" 2>/dev/null | cut -f1 || printf 'n/a'
}

#######################################
# Insert thousands separators into an integer, so record counts stay readable.
# Arguments:
#   $1 — integer.
# Outputs:
#   e.g. "39,747,727" on stdout.
#######################################
ui::number() {
  printf '%s' "${1:-0}" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
}

#######################################
# Shorten a path for display by replacing the artifact root with a marker.
# Arguments:
#   $1 — absolute path; $2 — the root to strip (typically REPO_ROOT).
# Outputs:
#   The path relative to the root, or the original if it lies outside it.
#######################################
ui::relpath() {
  local path="$1" root="${2:-}"
  if [[ -n "${root}" && "${path}" == "${root}"/* ]]; then
    printf '%s' "${path#"${root}"/}"
  else
    printf '%s' "${path}"
  fi
}
