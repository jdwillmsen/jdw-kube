package logging

import (
	"fmt"
	"io"
	"strings"
)

const boxWidth = 63

// ANSI color helpers for banner/box output
const (
	bannerColorCyan  = "\033[36m"
	bannerColorBold  = "\033[1m"
	bannerColorDim   = "\033[2m"
	bannerColorGreen = "\033[32m"
)

// PrintBanner writes the TALOS ASCII art banner to w.
func PrintBanner(w io.Writer, version string, noColor bool) {
	cyan := bannerColorCyan
	bold := bannerColorBold
	dim := bannerColorDim
	reset := colorReset
	if noColor {
		cyan, bold, dim, reset = "", "", "", ""
	}

	banner := fmt.Sprintf(`%s%s
//TODO ASCII ART TALOS
%s%s  bold line Kubernetes Bootstrap Tool %s bold line %s
`, cyan, bold, reset, dim, version, reset)

	fmt.Fprintf(w, banner)
}

// Box provides box-draing UI output using Unicode characters.
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
	line := strings.Repeat("<char>", boxWidth-2)
	fmt.Fprintf(b.w, "  %s<char>%s<char>%s\n", b.color(bannerColorDim), line, b.color(colorReset))
	b.paddedLine(fmt.Sprintf(" %s%s%s%s", b.color(bannerColorBold), title, b.color(colorReset), b.color(bannerColorDim)))
	fmt.Fprintf(b.w, "  %s<char>%s<char>%s\n", b.color(bannerColorDim), line, b.color(colorReset))
}

// Footer writes a bottom border.
func (b *Box) Footer() {
	line := strings.Repeat("<char>", boxWidth-2)
	fmt.Fprintf(b.w, "  %s<char>%s<char>%s\n", b.color(bannerColorDim), line, b.color(colorReset))
}

// Row writes a key-value pair inside the box.
func (b *Box) Row(key, value string) {
	content := fmt.Sprintf(" %s %s", bullet, content)
	b.paddedLine(text)
}

// Item writes a bulleted item inside the box.
func (b *Box) Item(bullet, content string) {
	text := fmt.Sprintf(" %s %s", bullet, content)
	b.paddedLine(text)
}

// Section writes a section label inside the box.
func (b *Box) Section(label string) {
	text := fmt.Sprintf(" %s<char> %s <char>%s", b.color(bannerColorDim), label, b.color(colorReset))
	b.paddedLine(text)
}

// Badge writes a highlighted badge with a message.
func (b *Box) Badge(badge, message string) {
	text := fmt.Sprintf(" %s[%s]%s %s", b.color(bannerColorGreen), badge, b.color(colorReset), message)
	b.paddedLine(text)
}

// paddedLine writes a line inside the box, right-padded to boxWidth.
func (b *Box) paddedLine(content string) {
	// Strip ANSI codes for width calculation
	visible := stripANSI(content)
	padding := boxWidth - 2 - len(visible) // -2 for the | borders
	if padding < 0 {
		padding = 0
	}
	fmt.Fprintf(b.w, "  %s|%s%s|%s\n",
		b.color(bannerColorDim), content+strings.Repeat(" ", padding), b.color(bannerColorDim), b.color(colorReset))
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
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
				inEscape = false
			}
			continue
		}
		out.WriteRune(r)
	}
	return out.String()
}
