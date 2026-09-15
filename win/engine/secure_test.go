package engine

import "testing"

func TestSecureRoundTrip(t *testing.T) {
	if err := testSecureRoundTrip(); err != nil {
		t.Fatal(err)
	}
}
