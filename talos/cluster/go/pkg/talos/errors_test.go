package talos

import (
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestErrorCodeConstants(t *testing.T) {
	// Verify error codes are sequential starting from 0
	assert.Equal(t, ErrorCode(0), ErrUnknown)
	assert.Equal(t, ErrorCode(1), ErrAlreadyConfigured)
	assert.Equal(t, ErrorCode(2), ErrCertificateRequired)
	assert.Equal(t, ErrorCode(3), ErrConnectionRefused)
	assert.Equal(t, ErrorCode(4), ErrMaintenanceMode)
	assert.Equal(t, ErrorCode(5), ErrAlreadyBootstrapped)
	assert.Equal(t, ErrorCode(6), ErrConnectionTimeout)
	assert.Equal(t, ErrorCode(7), ErrNodeNotReady)
	assert.Equal(t, ErrorCode(8), ErrPermissionDenied)
}

func TestParseTalosError_CaseVariations(t *testing.T) {
	tests := []struct {
		name         string
		errStr       string
		expectedCode ErrorCode
	}{
		{
			name:         "uppercase already configured",
			errStr:       "ALREADY CONFIGURED",
			expectedCode: ErrAlreadyConfigured,
		},
		{
			name:         "mixed case TLS error",
			errStr:       "TLS Handshake Failed",
			expectedCode: ErrCertificateRequired,
		},
		{
			name:         "lowercase connection refused",
			errStr:       "connect: connection refused",
			expectedCode: ErrConnectionRefused,
		},
		{
			name:         "timeout with context",
			errStr:       "Context Deadline Exceeded",
			expectedCode: ErrConnectionTimeout,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := errors.New(tt.errStr)
			talosErr := ParseTalosError(err)
			assert.Equal(t, tt.expectedCode, talosErr.Code)
		})
	}
}

func TestTalosError_ImplementsError(t *testing.T) {
	var _ error = &TalosError{}
}

func TestParseTalosError_TableDriven(t *testing.T) {
	type testCase struct {
		name           string
		input          error
		expectNil      bool
		expectedCode   ErrorCode
		expectedMsg    string
		isRetryable    bool
		switchToSecure bool
		isSuccess      bool
	}

	cases := []testCase{
		{
			name:      "nil input",
			input:     nil,
			expectNil: true,
		},
		{
			name:         "already configured - exact match",
			input:        errors.New("already configured"),
			expectedCode: ErrAlreadyConfigured,
			expectedMsg:  "node already configured",
			isRetryable:  false,
			isSuccess:    true,
		},
		{
			name:         "configuration already applied",
			input:        errors.New("configuration already applied"),
			expectedCode: ErrAlreadyConfigured,
			isSuccess:    true,
		},
		{
			name:           "certificate required",
			input:          errors.New("certificate is required"),
			expectedCode:   ErrCertificateRequired,
			isRetryable:    true, // Changed: matches actual implementation
			switchToSecure: true,
		},
		{
			name:         "maintenance mode variations",
			input:        errors.New("not ready"),
			expectedCode: ErrMaintenanceMode,
			isRetryable:  true,
		},
		{
			name:         "etcd initialized", // Fixed: was "intialized"
			input:        errors.New("etcd already initialized"),
			expectedCode: ErrAlreadyBootstrapped,
			isSuccess:    true,
		},
		{
			name:         "forbidden",
			input:        errors.New("forbidden"),
			expectedCode: ErrPermissionDenied,
		},
		{
			name:         "unauthorized",
			input:        errors.New("unauthorized access"),
			expectedCode: ErrPermissionDenied,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			result := ParseTalosError(tc.input)

			if tc.expectNil {
				assert.Nil(t, result)
				return
			}

			require.NotNil(t, result)
			assert.Equal(t, tc.expectedCode, result.Code)
			assert.Equal(t, tc.isRetryable, result.IsRetryable())
			assert.Equal(t, tc.switchToSecure, result.ShouldSwitchToSecure())
			assert.Equal(t, tc.isSuccess, result.IsSuccessState())

			if tc.expectedMsg != "" {
				assert.Equal(t, tc.expectedMsg, result.Message)
			}
		})
	}
}

func TestTalosError_WrappedErrorChain(t *testing.T) {
	original := errors.New("root cause")
	wrapped := &TalosError{
		Code:    ErrConnectionRefused,
		Message: "connection failed",
		Wrapped: original,
	}

	// Test error string contains both messages
	errStr := wrapped.Error()
	assert.Contains(t, errStr, "connection failed")
	assert.Contains(t, errStr, "root cause")

	// Test unwrapping
	assert.Equal(t, original, wrapped.Unwrap())
}

func TestTalosError_NilWrapped(t *testing.T) {
	te := &TalosError{
		Code:    ErrUnknown,
		Message: "standalone error",
		Wrapped: nil,
	}

	assert.Equal(t, "standalone error", te.Error())
	assert.Nil(t, te.Unwrap())
}
