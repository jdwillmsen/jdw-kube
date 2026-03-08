package logging

import (
	"fmt"
	"io"
	"strings"
)

const boxWidth = 63

// ANSI colors
const (
	cReset  = "\033[0m"
	cBold   = "\033[1m"
	cDim    = "\033[2m"
	cCyan   = "\033[36m"
	cGreen  = "\033[32m"
	cBlue   = "\033[34m"
	cYellow = "\033[33m"
	cRed    = "\033[31m"
)

// Heavy box-drawing (for Header/Footer)
const (
	hTL = "┏" // U+250F
	hTR = "┓" // U+2513
	hBL = "┗" // U+2517
	hBR = "┛" // U+251B
	hH  = "━" // U+2501
	hV  = "┃" // U+2503
	hL  = "┣" // U+2523
	hR  = "┫" // U+252B
)

// Standard box-drawing (for Divider)
const (
	sTL = "┌" // U+250C
	sTR = "┐" // U+2510
	sBL = "└" // U+2514
	sBR = "┘" // U+2518
	sH  = "─" // U+2500
	sV  = "│" // U+2502
	sL  = "├" // U+251C
	sR  = "┤" // U+2524
	sT  = "┬" // U+252C
	sB  = "┴" // U+2534
	sC  = "┼" // U+253C
)

// Markers
const (
	mBullet  = "•" // U+2022
	mDiamond = "◆" // U+25C6
	mDot     = "·" // U+00B7
	mCheck   = "✓" // U+2713
	mCross   = "✗" // U+2717
	mWarning = "⚠" // U+26A0
	mInfo    = "ℹ" // U+2139
)

// talosASCIIArt is the filled block art for TALOS
const talosASCIIArt = `████████╗ █████╗ ██╗      ██████╗ ███████╗
╚══██╔══╝██╔══██╗██║     ██╔═══██╗██╔════╝
   ██║   ███████║██║     ██║   ██║███████╗
   ██║   ██╔══██║██║     ██║   ██║╚════██║
   ██║   ██║  ██║███████╗╚██████╔╝███████║
   ╚═╝   ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚══════╝`

// PrintBanner writes the TALOS banner to w.
func PrintBanner(w io.Writer, version string, noColor bool) {
	cc, cb, cd, cr := cCyan, cBold, cDim, cReset
	if noColor {
		cc, cb, cd, cr = "", "", "", ""
	}
	fmt.Fprintf(w, "%s%s%s\n%s%s ━━━ Kubernetes Bootstrap Tool %s ━━━%s\n",
		cc, cb, talosASCIIArt, cr, cd, version, cr)
}

// Box provides box-drawing UI output.
type Box struct {
	w       io.Writer
	noColor bool
}

// NewBox creates a Box that writes to w.
func NewBox(w io.Writer, noColor bool) *Box {
	return &Box{w: w, noColor: noColor}
}

func (b *Box) c(code string) string {
	if b.noColor {
		return ""
	}
	return code
}

// writeLine writes content with heavy vertical borders and padding.
func (b *Box) writeLine(content string) {
	visible := stripANSI(content)
	padding := boxWidth - 2 - len(visible)
	if padding < 0 {
		padding = 0
	}
	fmt.Fprintf(b.w, "%s%s%s%s%s%s%s%s\n",
		b.c(cDim), hV, b.c(cReset),
		content,
		strings.Repeat(" ", padding),
		b.c(cDim), hV, b.c(cReset))
}

// Header writes the heavy top border and title with subtitle.
func (b *Box) Header(title string) {
	top := strings.Repeat(hH, boxWidth-2)
	fmt.Fprintf(b.w, "%s%s%s%s%s\n",
		b.c(cDim), hTL, top, hTR, b.c(cReset))

	b.writeLine(fmt.Sprintf(" %s%s%s%s%s", b.c(cCyan), b.c(cBold), title, b.c(cReset), b.c(cDim)))

	sep := strings.Repeat(hH, boxWidth-2)
	fmt.Fprintf(b.w, "%s%s%s%s%s\n",
		b.c(cDim), hL, sep, hR, b.c(cReset))
}

// Footer writes the heavy bottom border.
func (b *Box) Footer() {
	bottom := strings.Repeat(hH, boxWidth-2)
	fmt.Fprintf(b.w, "%s%s%s%s%s\n",
		b.c(cDim), hBL, bottom, hBR, b.c(cReset))
}

// Divider writes a standard horizontal separator.
func (b *Box) Divider() {
	sep := strings.Repeat(sH, boxWidth-2)
	fmt.Fprintf(b.w, "%s%s%s%s%s\n",
		b.c(cDim), sL, sep, sR, b.c(cReset))
}

// Row writes a key: value pair.
func (b *Box) Row(key, value string) {
	b.writeLine(fmt.Sprintf("  %s%s:%s %s%s%s", b.c(cBold), key, b.c(cReset), b.c(cCyan), value, b.c(cReset)))
}

// Item writes a bulleted item with color based on the marker.
func (b *Box) Item(marker, text string) {
	var color string
	switch marker {
	case "+":
		color = cGreen
	case "-":
		color = cRed
	case "~":
		color = cYellow
	case mCheck:
		color = cGreen
	case mCross:
		color = cRed
	case mWarning:
		color = cYellow
	}
	if color != "" {
		b.writeLine(fmt.Sprintf("  %s%s%s %s", b.c(color), marker, b.c(cReset), text))
	} else {
		b.writeLine(fmt.Sprintf("  %s %s", marker, text))
	}
}

// Section writes a centered section header with diamond markers and dotted line.
func (b *Box) Section(label string) {
	text := fmt.Sprintf("%s%s %s%s %s%s",
		b.c(cDim), mDiamond,
		b.c(cBold)+label+b.c(cReset),
		b.c(cDim), mDiamond, b.c(cReset))

	visible := stripANSI(text)
	padding := boxWidth - 2 - len(visible)
	leftPad := padding / 2
	rightPad := padding - leftPad

	content := strings.Repeat(" ", leftPad) + text + strings.Repeat(" ", rightPad)
	b.writeLine(content)

	dots := strings.Repeat(mDot, boxWidth-2)
	b.writeLine(b.c(cDim) + dots + b.c(cReset))
}

// Badge writes a colored [BADGE] message. Color is chosen by badge name:
// OK/SUCCESS -> green, BOOTSTRAP/INFO/WARN -> yellow, ERROR/FAIL -> red.
func (b *Box) Badge(badge, msg string) {
	var color string
	switch badge {
	case "OK", "SUCCESS", "PASS":
		color = cGreen
	case "ERROR", "FAIL":
		color = cRed
	default:
		color = cYellow
	}
	b.writeLine(fmt.Sprintf("  %s[%s]%s %s", b.c(color), badge, b.c(cReset), msg))
}

// stripANSI removes ANSI escape sequences.
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
