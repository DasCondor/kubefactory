package main

import (
	"encoding/json"

	"k8s.io/apimachinery/pkg/api/resource"
)

// A partial sum is not a pod total: omit a metric if any container lacks it.
func parsePodMetrics(body []byte) (map[string]any, error) {
	var m struct {
		Timestamp  string `json:"timestamp"`
		Window     string `json:"window"`
		Containers []struct {
			Usage map[string]string `json:"usage"`
		} `json:"containers"`
	}
	if json.Unmarshal(body, &m) != nil {
		return nil, fail("unsupported", "the metrics API answered in a form this version does not read")
	}
	if len(m.Containers) == 0 {
		return nil, fail("unsupported", "the metrics API returned no container measurements")
	}
	out := map[string]any{"at": m.Timestamp, "window": m.Window, "source": "metrics.k8s.io"}
	for _, field := range []struct{ api, output string }{{"cpu", "cpu_cores"}, {"memory", "mem_bytes"}} {
		total, complete := 0.0, true
		for _, c := range m.Containers {
			q, err := resource.ParseQuantity(c.Usage[field.api])
			if err != nil || q.Sign() < 0 {
				complete = false
				break
			}
			total += q.AsApproximateFloat64()
		}
		if complete {
			out[field.output] = total
		}
	}
	return out, nil
}
