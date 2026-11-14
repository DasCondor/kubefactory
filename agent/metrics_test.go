package main

import "testing"

func TestPodMetricsRequireCompleteMeasurements(t *testing.T) {
	valid := []byte(`{"timestamp":"now","containers":[{"usage":{"cpu":"250m","memory":"128Mi"}},{"usage":{"cpu":"750m","memory":"64Mi"}}]}`)
	got, err := parsePodMetrics(valid)
	if err != nil || got["cpu_cores"] != 1.0 || got["mem_bytes"] != float64(192*1024*1024) {
		t.Fatalf("valid totals: %v, %v", got, err)
	}
	partial := []byte(`{"containers":[{"usage":{"cpu":"0","memory":"1Mi"}},{"usage":{"cpu":"bad","memory":"2Mi"}}]}`)
	got, err = parsePodMetrics(partial)
	if err != nil || got["cpu_cores"] != nil || got["mem_bytes"] != float64(3*1024*1024) {
		t.Fatalf("incomplete CPU must be absent: %v, %v", got, err)
	}
	got, err = parsePodMetrics([]byte(`{"containers":[{"usage":{"cpu":"0","memory":"-1Mi"}}]}`))
	if err != nil || got["cpu_cores"] != 0.0 || got["mem_bytes"] != nil {
		t.Fatalf("zero and invalid memory: %v, %v", got, err)
	}
	if _, err := parsePodMetrics([]byte(`{"containers":[]}`)); err == nil {
		t.Fatal("empty container metrics must be unavailable")
	}
}
