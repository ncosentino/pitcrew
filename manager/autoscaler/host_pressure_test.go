package main

import (
	"errors"
	"math"
	"path/filepath"
	"testing"
)

func TestHostPressureSamplingBecomesAvailableAfterCPUBaseline(t *testing.T) {
	files := completeHostPressureFiles(
		"cpu 100 0 50 800 50 0 0 0 0 0\n",
	)
	docker := &dockerCLI{
		hostProcPath: "/host/proc",
		readHostFile: func(path string) ([]byte, error) {
			value, exists := files[filepath.ToSlash(path)]
			if !exists {
				return nil, errors.New("missing fixture")
			}
			return []byte(value), nil
		},
	}

	first := docker.sampleHostPressure()
	if first.Status != "partial" ||
		first.Source != "docker-host" ||
		first.CPUUtilizationPercent != nil ||
		first.Load1 == nil ||
		first.MemoryAvailableBytes == nil {
		t.Fatalf("first host-pressure sample was not explicitly partial: %#v", first)
	}

	files["/host/proc/stat"] = "cpu 150 0 100 850 100 0 0 0 0 0\n"
	second := docker.sampleHostPressure()
	if second.Status != "available" ||
		second.CPUUtilizationPercent == nil ||
		math.Abs(*second.CPUUtilizationPercent-50) > 0.000001 ||
		second.Load1 == nil ||
		*second.Load1 != 12.5 ||
		second.MemoryTotalBytes == nil ||
		*second.MemoryTotalBytes != 34359738368 ||
		second.MemoryAvailableBytes == nil ||
		*second.MemoryAvailableBytes != 8589934592 ||
		second.SwapUsedBytes == nil ||
		*second.SwapUsedBytes != 1073741824 ||
		second.CPUPressureSomeAvg10 == nil ||
		*second.CPUPressureSomeAvg10 != 21.5 ||
		second.MemoryPressureFullAvg10 == nil ||
		*second.MemoryPressureFullAvg10 != 4.5 ||
		second.IOPressureSomeAvg10 == nil ||
		*second.IOPressureSomeAvg10 != 30.25 {
		t.Fatalf("host pressure was not normalized correctly: %#v", second)
	}
}

func TestHostPressureSamplingDoesNotRequirePSI(t *testing.T) {
	files := completeHostPressureFiles(
		"cpu 100 0 50 800 50 0 0 0\n",
	)
	delete(files, "/host/proc/pressure/cpu")
	delete(files, "/host/proc/pressure/memory")
	delete(files, "/host/proc/pressure/io")
	docker := &dockerCLI{
		hostProcPath: "/host/proc",
		readHostFile: fixtureReader(files),
		previousHostCPU: &hostCPUCounters{
			total: 900,
			idle:  800,
		},
	}
	pressure := docker.sampleHostPressure()
	if pressure.Status != "available" ||
		pressure.CPUPressureSomeAvg10 != nil ||
		pressure.MemoryPressureSomeAvg10 != nil ||
		pressure.IOPressureSomeAvg10 != nil {
		t.Fatalf("optional PSI changed core availability: %#v", pressure)
	}
}

func TestHostPressureSamplingRejectsCounterRegression(t *testing.T) {
	files := completeHostPressureFiles(
		"cpu 10 0 10 80 0 0 0 0\n",
	)
	docker := &dockerCLI{
		hostProcPath: "/host/proc",
		readHostFile: fixtureReader(files),
		previousHostCPU: &hostCPUCounters{
			total: 1000,
			idle:  800,
		},
	}
	pressure := docker.sampleHostPressure()
	if pressure.Status != "partial" || pressure.CPUUtilizationPercent != nil {
		t.Fatalf("counter regression fabricated CPU utilization: %#v", pressure)
	}
	if docker.previousHostCPU == nil || docker.previousHostCPU.total != 100 {
		t.Fatalf("counter regression did not reset the baseline: %#v", docker.previousHostCPU)
	}
}

func TestHostPressureSamplingUnavailableWhenHostProcCannotBeRead(t *testing.T) {
	docker := &dockerCLI{
		hostProcPath: "/host/proc",
		readHostFile: func(string) ([]byte, error) {
			return nil, errors.New("unavailable")
		},
	}
	pressure := docker.sampleHostPressure()
	if pressure.Status != "unavailable" ||
		pressure.Source != "docker-host" ||
		hostPressureHasMeasurement(pressure) {
		t.Fatalf("unavailable host proc fabricated pressure: %#v", pressure)
	}
}

func TestHostPressureParsersRejectMalformedInput(t *testing.T) {
	if _, err := parseHostCPUCounters([]byte("cpu invalid\n")); err == nil {
		t.Fatal("invalid CPU counters were accepted")
	}
	load1, load5, load15 := parseLoadAverages([]byte("NaN -1 nope\n"))
	if load1 != nil || load5 != nil || load15 != nil {
		t.Fatal("invalid load averages were accepted")
	}
	total, available, swap := parseHostMemory([]byte(
		"MemTotal: 100 kB\nMemAvailable: 200 kB\n",
	))
	if total != nil || available != nil || swap != nil {
		t.Fatal("impossible memory availability was accepted")
	}
	some, full := parsePSIAvg10([]byte(
		"some avg10=101.00 avg60=0.00 avg300=0.00 total=1\n" +
			"full avg10=NaN avg60=0.00 avg300=0.00 total=1\n",
	))
	if some != nil || full != nil {
		t.Fatal("invalid pressure percentages were accepted")
	}
}

func completeHostPressureFiles(stat string) map[string]string {
	return map[string]string{
		"/host/proc/stat":    stat,
		"/host/proc/loadavg": "12.50 8.25 4.00 3/100 123\n",
		"/host/proc/meminfo": "" +
			"MemTotal:       33554432 kB\n" +
			"MemAvailable:    8388608 kB\n" +
			"SwapTotal:       2097152 kB\n" +
			"SwapFree:        1048576 kB\n",
		"/host/proc/pressure/cpu": "" +
			"some avg10=21.50 avg60=12.00 avg300=4.00 total=1\n" +
			"full avg10=3.25 avg60=2.00 avg300=1.00 total=1\n",
		"/host/proc/pressure/memory": "" +
			"some avg10=9.50 avg60=8.00 avg300=7.00 total=1\n" +
			"full avg10=4.50 avg60=3.00 avg300=2.00 total=1\n",
		"/host/proc/pressure/io": "" +
			"some avg10=30.25 avg60=20.00 avg300=10.00 total=1\n" +
			"full avg10=15.00 avg60=10.00 avg300=5.00 total=1\n",
	}
}

func fixtureReader(files map[string]string) func(string) ([]byte, error) {
	return func(path string) ([]byte, error) {
		value, exists := files[filepath.ToSlash(path)]
		if !exists {
			return nil, errors.New("missing fixture")
		}
		return []byte(value), nil
	}
}
