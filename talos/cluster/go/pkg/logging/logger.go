package logging

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"

	"github.com/jdw/talos-bootstrap/pkg/types"
)

// ANSI color codes matching bash script
const (
	colorReset     = "\033[0m"
	colorRed       = "\033[31m"
	colorYellow    = "\033[33m"
	colorBlue      = "\033[34m"
	colorWhite     = "\033[37m"
	colorWhiteOnRd = "\033[37;41m" // white text on red background
)

// RunSession manages a single bootstrap run's log files and lifecycle
type RunSession struct {
	RunDir     string
	StartTime  time.Time
	Logger     *zap.Logger
	AuditLog   *AuditLogger
	NoColor    bool
	Config     *types.Config
	closers    []io.Closer
	runsLogDir string

	// Operational counters for SUMMARY.txt (set by caller during execution)
	ControlPlanes   int
	Workers         int
	AddedNodes      int
	RemovedNodes    int
	UpdatedConfigs  int
	BootstrapNeeded bool
}

// NewRunSession creates a timestamped run directory, opens log files,
// and builds a tee'd zap.Logger writing to stderr + console.log + structured.log.
func NewRunSession(cfg *types.Config) (*RunSession, error) {
	now := time.Now()
	dateDir := now.Format("2006-01-02")
	runName := "run-" + now.Format("20060102_150405")
	runDir := filepath.Join(cfg.LogDir, dateDir, runName)

	if err := os.MkdirAll(runDir, 0755); err != nil {
		return nil, fmt.Errorf("create run directory %s: %w", runDir, err)
	}

	// Open log files
	consoleFile, err := os.Create(filepath.Join(runDir, "console.log"))
	if err != nil {
		return nil, fmt.Errorf("create console.log: %w", err)
	}

	structuredFile, err := os.Create(filepath.Join(runDir, "structured.log"))
	if err != nil {
		consoleFile.Close()
		return nil, fmt.Errorf("create structured.log: %w", err)
	}

	auditFile, err := os.Create(filepath.Join(runDir, "audit.log"))
	if err != nil {
		consoleFile.Close()
		structuredFile.Close()
		return nil, fmt.Errorf("create audit.log: %w", err)
	}

	// Parse log level
	level := parseZapLevel(cfg.LogLevel)

	// Build tee core
	teeCore := buildTeeCore(level, cfg.NoColor, consoleFile, structuredFile)

	logger := zap.New(teeCore, zap.AddCaller(), zap.AddStacktrace(zap.FatalLevel))

	session := &RunSession{
		RunDir:     runDir,
		StartTime:  now,
		Logger:     logger,
		AuditLog:   NewAuditLogger(auditFile),
		NoColor:    cfg.NoColor,
		Config:     cfg,
		closers:    []io.Closer{consoleFile, structuredFile, auditFile},
		runsLogDir: cfg.LogDir,
	}

	// Write to runs.log registry
	session.registerRun()

	// Update latest.txt symlink
	session.updateLatest()

	// Write session header
	session.writeHeader()

	return session, nil
}

// buildTeeCore creates a zapcore.Core that fans out to 3 sinks:
// stderr (colored console), console.log (colored console), structured.log (JSON)
func buildTeeCore(level zapcore.Level, noColor bool, consoleFile, structuredFile io.Writer) zapcore.Core {
	// Console encoder config (colored for stderr and console.log)
	consoleCfg := newConsoleEncoderConfig(noColor)
	consoleEncoder := zapcore.NewConsoleEncoder(consoleCfg)

	// JSON encoder config (for structured.log)
	jsonCfg := zap.NewProductionEncoderConfig()
	jsonCfg.TimeKey = "ts"
	jsonCfg.EncodeTime = zapcore.ISO8601TimeEncoder
	jsonEncoder := zapcore.NewJSONEncoder(jsonCfg)

	levelEnabler := zap.LevelEnablerFunc(func(lvl zapcore.Level) bool {
		return lvl >= level
	})

	return zapcore.NewTee(
		zapcore.NewCore(consoleEncoder, zapcore.Lock(os.Stderr), levelEnabler),
		zapcore.NewCore(consoleEncoder, zapcore.AddSync(consoleFile), levelEnabler),
		zapcore.NewCore(jsonEncoder, zapcore.AddSync(structuredFile), levelEnabler),
	)
}

// newConsoleEncoderConfig returns a console encoder config with custom ANSI colors
func newConsoleEncoderConfig(noColor bool) zapcore.EncoderConfig {
	cfg := zap.NewDevelopmentEncoderConfig()
	cfg.EncodeTime = zapcore.TimeEncoderOfLayout("2006-01-02 15:04:05")
	if !noColor {
		cfg.EncodeLevel = colorLevelEncoder
	}
	return cfg
}

// colorLevelEncoder maps zap levels to ANSI colors matching the bash script
func colorLevelEncoder(l zapcore.Level, enc zapcore.PrimitiveArrayEncoder) {
	var color string
	switch l {
	case zapcore.FatalLevel:
		color = colorWhiteOnRd
	case zapcore.ErrorLevel:
		color = colorRed
	case zapcore.WarnLevel:
		color = colorYellow
	case zapcore.DebugLevel:
		color = colorBlue
	default: // Info
		color = colorWhite
	}
	enc.AppendString(color + l.CapitalString() + colorReset)
}

func parseZapLevel(s string) zapcore.Level {
	switch strings.ToLower(s) {
	case "debug", "trace":
		return zap.DebugLevel
	case "warn", "warning":
		return zap.WarnLevel
	case "error":
		return zap.ErrorLevel
	default:
		return zap.InfoLevel
	}
}

// registerRun appends a pending entry to runs.log
func (s *RunSession) registerRun() {
	runsLogPath := filepath.Join(s.runsLogDir, "runs.log")
	// Ensure parent dir exists
	os.MkdirAll(filepath.Dir(runsLogPath), 0755)

	entry := fmt.Sprintf("%s|%s|%s|pending\n",
		s.StartTime.Format("2006-01-02 15:04:05"),
		s.Config.ClusterName,
		s.RunDir,
	)

	f, err := os.OpenFile(runsLogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	f.WriteString(entry)
}

// updateLatest writes the current run directory to latest.txt
func (s *RunSession) updateLatest() {
	latestPath := filepath.Join(s.runsLogDir, "latest.txt")
	os.MkdirAll(filepath.Dir(latestPath), 0755)
	os.WriteFile(latestPath, []byte(s.RunDir+"\n"), 0644)
}

// writeHeader writes a session header to all log outputs
func (s *RunSession) writeHeader() {
	header := fmt.Sprintf("=== Talos Bootstrap Session ===\n"+
		"  Start:   %s\n"+
		"  Cluster: %s\n"+
		"  Config:  %s\n"+
		"  Log Dir: %s\n",
		s.StartTime.Format("2006-01-02 15:04:05"),
		s.Config.ClusterName,
		s.Config.TerraformTFVars,
		s.RunDir,
	)
	s.Logger.Info(header)
}

// Close finalizes the run session: writes SUMMARY.txt, updates runs.log status,
// flushes the logger, and closes all file handles.
func (s *RunSession) Close(exitErr error) {
	duration := time.Since(s.StartTime)

	// Determine status
	status := "success"
	if exitErr != nil {
		status = "failed"
	}

	// Write SUMMARY.txt
	summary := SummaryData{
		StartTime:       s.StartTime,
		Duration:        duration,
		Status:          status,
		ClusterName:     s.Config.ClusterName,
		RunDir:          s.RunDir,
		ExitError:       exitErr,
		ControlPlanes:   s.ControlPlanes,
		Workers:         s.Workers,
		AddedNodes:      s.AddedNodes,
		RemovedNodes:    s.RemovedNodes,
		UpdatedConfigs:  s.UpdatedConfigs,
		BootstrapNeeded: s.BootstrapNeeded,
	}
	WriteSummary(filepath.Join(s.RunDir, "SUMMARY.txt"), &summary)

	// Update runs.log: change last "pending" entry for this run to final status
	s.updateRunsLogStatus(status)

	// Flush zap
	s.Logger.Sync()

	// Close file handles
	for _, c := range s.closers {
		c.Close()
	}
}

// updateRunsLogStatus replaces the status of this run's entry in runs.log
func (s *RunSession) updateRunsLogStatus(status string) {
	runsLogPath := filepath.Join(s.runsLogDir, "runs.log")
	data, err := os.ReadFile(runsLogPath)
	if err != nil {
		return
	}

	lines := strings.Split(string(data), "\n")
	for i, line := range lines {
		if strings.Contains(line, s.RunDir) && strings.HasSuffix(line, "pending") {
			lines[i] = strings.TrimSuffix(line, "pending") + status
			break
		}
	}

	os.WriteFile(runsLogPath, []byte(strings.Join(lines, "\n")), 0644)
}
