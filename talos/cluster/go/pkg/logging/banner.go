package logging

import (
	"fmt"
	"io"
	"strings"
)

const boxWidth = 63

// ANSI color helpers for banner/box output
const (
	bannerColorCyan    = "\033[36m"
	bannerColorBold    = "\033[1m"
	bannerColorDim     = "\033[2m"
	bannerColorGreen   = "\033[32m"
	bannerColorYellow  = "\033[33m"
	bannerColorBlue    = "\033[34m"
	bannerColorMagenta = "\033[35m"
	bannerColorRed     = "\033[31m"
	bannerColorWhite   = "\033[37m"
)

// talosASCIIArt is the Claude Code-style filled block art for TALOS
const talosASCIIArt = `
████████╗ █████╗ ██╗      ██████╗ ███████╗
╚══██╔══╝██╔══██╗██║     ██╔═══██╗██╔════╝
   ██║   ███████║██║     ██║   ██║███████╗
   ██║   ██╔══██║██║     ██║   ██║╚════██║
   ██║   ██║  ██║███████╗╚██████╔╝███████║
   ╚═╝   ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚══════╝
`

// PrintBanner writes the TALOS ASCII art banner to w.
func PrintBanner(w io.Writer, version string, noColor bool) {
	cyan := bannerColorCyan
	bold := bannerColorBold
	dim := bannerColorDim
	blue := bannerColorBlue
	reset := colorReset

	if noColor {
		cyan, bold, dim, blue, reset = "", "", "", "", ""
	}

	// Print the filled block ASCII art with cyan coloring
	fmt.Fprintf(w, "%s%s%s\n", cyan, talosASCIIArt, reset)

	// Print the subtitle with styling
	fmt.Fprintf(w, "%s%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n", dim, bold, reset)
	fmt.Fprintf(w, "%s%s   Kubernetes Bootstrap Tool %s%s%s%s\n", dim, bold, reset, blue, version, reset)
	fmt.Fprintf(w, "%s%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n", dim, bold, reset)
}

// Box provides box-drawing UI output using Unicode characters.
type Box struct {
	w       io.Writer
	noColor bool
}

// NewBox creates a Box that writes to w.
func NewBox(w io.Writer, noColor bool) *Box {
	return &Box{w: w, noColor: noColor}
}

func (b *Box) color(code string) string {
	if b.noColor {
		return ""
	}
	return code
}

// Header writes a top border and title line.
func (b *Box) Header(title string) {
	// Top border with rounded corners
	line := strings.Repeat("─", boxWidth-2)
	fmt.Fprintf(b.w, "  %s╭%s╮%s\n", b.color(bannerColorDim), line, b.color(colorReset))

	// Title line centered
	titleStr := fmt.Sprintf(" %s%s%s ", b.color(bannerColorBold), title, b.color(colorReset))
	visibleTitle := stripANSI(titleStr)
	padding := boxWidth - 2 - len(visibleTitle)
	if padding < 0 {
		padding = 0
	}
	leftPad := padding / 2
	rightPad := padding - leftPad

	fmt.Fprintf(b.w, "  %s│%s%s%s%s│%s\n",
		b.color(bannerColorDim),
		strings.Repeat(" ", leftPad),
		titleStr,
		strings.Repeat(" ", rightPad),
		b.color(bannerColorDim),
		b.color(colorReset))

	// Separator line
	sepLine := strings.Repeat("─", boxWidth-2)
	fmt.Fprintf(b.w, "  %s├%s┤%s\n", b.color(bannerColorDim), sepLine, b.color(colorReset))
}

// Footer writes a bottom border.
func (b *Box) Footer() {
	line := strings.Repeat("─", boxWidth-2)
	fmt.Fprintf(b.w, "  %s╰%s╯%s\n", b.color(bannerColorDim), line, b.color(colorReset))
}

// Row writes a key-value pair inside the box.
func (b *Box) Row(key, value string) {
	// Format: "  key: value" with proper spacing
	keyPart := fmt.Sprintf("  %s%s:%s ", b.color(bannerColorBold), key, b.color(colorReset))
	valuePart := fmt.Sprintf("%s", value)

	content := keyPart + valuePart
	visible := stripANSI(content)
	padding := boxWidth - 2 - len(visible)
	if padding < 0 {
		padding = 0
	}

	fmt.Fprintf(b.w, "  %s│%s%s%s│%s\n",
		b.color(bannerColorDim),
		content,
		strings.Repeat(" ", padding),
		b.color(bannerColorDim),
		b.color(colorReset))
}

// Item writes a bulleted item inside the box.
func (b *Box) Item(bullet, content string) {
	text := fmt.Sprintf("  %s %s", bullet, content)
	visible := stripANSI(text)
	padding := boxWidth - 2 - len(visible)
	if padding < 0 {
		padding = 0
	}

	fmt.Fprintf(b.w, "  %s│%s%s%s│%s\n",
		b.color(bannerColorDim),
		text,
		strings.Repeat(" ", padding),
		b.color(bannerColorDim),
		b.color(colorReset))
}

// Section writes a section label inside the box.
func (b *Box) Section(label string) {
	// Section with decorative arrows
	text := fmt.Sprintf("  %s◆ %s %s◆%s",
		b.color(bannerColorDim),
		b.color(bannerColorBold)+label+b.color(colorReset),
		b.color(bannerColorDim),
		b.color(colorReset))

	visible := stripANSI(text)
	padding := boxWidth - 2 - len(visible)
	if padding < 0 {
		padding = 0
	}
	leftPad := padding / 2
	rightPad := padding - leftPad

	fmt.Fprintf(b.w, "  %s│%s%s%s%s│%s\n",
		b.color(bannerColorDim),
		strings.Repeat(" ", leftPad),
		text,
		strings.Repeat(" ", rightPad),
		b.color(bannerColorDim),
		b.color(colorReset))

	// Sub-separator
	sepLine := strings.Repeat("·", boxWidth-2)
	fmt.Fprintf(b.w, "  %s│%s%s%s│%s\n",
		b.color(bannerColorDim),
		b.color(bannerColorDim),
		sepLine,
		b.color(bannerColorDim),
		b.color(colorReset))
}

// Badge writes a highlighted badge with a message.
func (b *Box) Badge(badge, message string) {
	text := fmt.Sprintf("  %s[%s]%s %s",
		b.color(bannerColorGreen),
		badge,
		b.color(colorReset),
		message)

	visible := stripANSI(text)
	padding := boxWidth - 2 - len(visible)
	if padding < 0 {
		padding = 0
	}

	fmt.Fprintf(b.w, "  %s│%s%s%s│%s\n",
		b.color(bannerColorDim),
		text,
		strings.Repeat(" ", padding),
		b.color(bannerColorDim),
		b.color(colorReset))
}

// Info writes an info-style row with blue indicator.
func (b *Box) Info(message string) {
	text := fmt.Sprintf("  %sℹ%s  %s",
		b.color(bannerColorBlue),
		b.color(colorReset),
		message)

	visible := stripANSI(text)
	padding := boxWidth - 2 - len(visible)
	if padding < 0 {
		padding = 0
	}

	fmt.Fprintf(b.w, "  %s│%s%s%s│%s\n",
		b.color(bannerColorDim),
		text,
		strings.Repeat(" ", padding),
		b.color(bannerColorDim),
		b.color(colorReset))
}

// Success writes a success-style row with green checkmark.
func (b *Box) Success(message string) {
	text := fmt.Sprintf("  %s✓%s  %s",
		b.color(bannerColorGreen),
		b.color(colorReset),
		message)

	visible := stripANSI(text)
	padding := boxWidth - 2 - len(visible)
	if padding < 0 {
		padding = 0
	}

	fmt.Fprintf(b.w, "  %s│%s%s%s│%s\n",
		b.color(bannerColorDim),
		text,
		strings.Repeat(" ", padding),
		b.color(bannerColorDim),
		b.color(colorReset))
}

// Warning writes a warning-style row with yellow indicator.
func (b *Box) Warning(message string) {
	text := fmt.Sprintf("  %s⚠%s  %s",
		b.color(bannerColorYellow),
		b.color(colorReset),
		message)

	visible := stripANSI(text)
	padding := boxWidth - 2 - len(visible)
	if padding < 0 {
		padding = 0
	}

	fmt.Fprintf(b.w, "  %s│%s%s%s│%s\n",
		b.color(bannerColorDim),
		text,
		strings.Repeat(" ", padding),
		b.color(bannerColorDim),
		b.color(colorReset))
}

// Error writes an error-style row with red indicator.
func (b *Box) Error(message string) {
	text := fmt.Sprintf("  %s✗%s  %s",
		b.color(bannerColorRed),
		b.color(colorReset),
		message)

	visible := stripANSI(text)
	padding := boxWidth - 2 - len(visible)
	if padding < 0 {
		padding = 0
	}

	fmt.Fprintf(b.w, "  %s│%s%s%s│%s\n",
		b.color(bannerColorDim),
		text,
		strings.Repeat(" ", padding),
		b.color(bannerColorDim),
		b.color(colorReset))
}

// Empty writes an empty line inside the box.
func (b *Box) Empty() {
	fmt.Fprintf(b.w, "  %s│%s│%s\n",
		b.color(bannerColorDim),
		strings.Repeat(" ", boxWidth-2),
		b.color(colorReset))
}

// Separator writes a horizontal separator line inside the box.
func (b *Box) Separator() {
	line := strings.Repeat("─", boxWidth-2)
	fmt.Fprintf(b.w, "  %s├%s┤%s\n", b.color(bannerColorDim), line, b.color(colorReset))
}

// stripANSI removes ANSI escape sequences for visible-length calculation.
func stripANSI(s string) string {
	var out strings.Builder
	inEscape := false
	for _, r := range s {
		if r == '\033' {
			inEscape = true
			continue
		}
		if inEscape {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == ']' {
				inEscape = false
			} else if r == '[' {
				continue
			}
			continue
		}
		out.WriteRune(r)
	}
	return out.String()
}
