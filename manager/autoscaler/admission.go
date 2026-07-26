package main

import (
	"sort"
	"sync"
)

// admissionController enforces one profile-wide active-worker ceiling across
// every target controller. Admission is reserved centrally before a JIT runner
// is generated, so locally live, starting, recovered, draining, cleanup-pending,
// and in-flight workers can never overshoot the ceiling during simultaneous
// scale-up. The controller only limits admission; it never removes a worker.
type admissionController struct {
	mu       sync.Mutex
	ceiling  int
	members  map[string]*admissionMember
	rotation int
}

type admissionMember struct {
	live     func() int
	demand   int
	inFlight int
}

func newAdmissionController(ceiling int) *admissionController {
	if ceiling < 0 {
		ceiling = 0
	}
	return &admissionController{
		ceiling: ceiling,
		members: make(map[string]*admissionMember),
	}
}

// join registers one capacity source. The live function reports every local
// worker the source currently holds, including draining and cleanup-pending
// workers, so a lower ceiling never authorizes deleting an existing worker.
func (a *admissionController) join(key string, live func() int) {
	if a == nil || key == "" || live == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if member, exists := a.members[key]; exists {
		member.live = live
		return
	}
	a.members[key] = &admissionMember{live: live}
}

func (a *admissionController) leave(key string) {
	if a == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.members, key)
	if a.rotation > len(a.members) {
		a.rotation = 0
	}
}

// reserve admits up to want additional workers for one target. Each target is
// guaranteed a rotating fair share of the ceiling, and unclaimed capacity is
// released to whichever target needs it, so no target starves and idle targets
// never strand capacity.
func (a *admissionController) reserve(key string, want int) int {
	if a == nil || want <= 0 {
		return max(want, 0)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	member, exists := a.members[key]
	if !exists {
		return want
	}
	member.demand = want
	if a.ceiling <= 0 {
		return want
	}

	keys := a.orderedKeysLocked()
	held := make(map[string]int, len(keys))
	total := 0
	for _, memberKey := range keys {
		count := a.members[memberKey].heldCount()
		held[memberKey] = count
		total += count
	}
	free := a.ceiling - total
	if free <= 0 {
		return 0
	}

	granted := 0
	guarantee := a.shareLocked(keys, key)
	if held[key] < guarantee {
		granted = min(want, guarantee-held[key], free)
	}
	if granted < want {
		protected := 0
		for _, otherKey := range keys {
			if otherKey == key {
				continue
			}
			other := a.members[otherKey]
			need := other.demand - held[otherKey]
			if need <= 0 {
				continue
			}
			protected += min(need, a.shareLocked(keys, otherKey))
		}
		if surplus := free - granted - protected; surplus > 0 {
			granted += min(want-granted, surplus)
		}
	}
	if granted > 0 {
		member.inFlight += granted
		if len(keys) > 0 {
			a.rotation = (a.rotation + 1) % len(keys)
		}
	}
	member.demand = want - granted
	return granted
}

// settle releases in-flight admissions once each launch attempt has either
// produced a tracked worker or failed.
func (a *admissionController) settle(key string, count int) {
	if a == nil || count <= 0 {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	member, exists := a.members[key]
	if !exists {
		return
	}
	member.inFlight = max(member.inFlight-count, 0)
}

func (a *admissionController) limit() int {
	if a == nil {
		return 0
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.ceiling
}

func (a *admissionController) orderedKeysLocked() []string {
	keys := make([]string, 0, len(a.members))
	for key := range a.members {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// shareLocked derives one target's guaranteed portion of the ceiling. The
// remainder rotates after every grant so repeated contention cannot always
// favor the same target.
func (a *admissionController) shareLocked(keys []string, key string) int {
	count := len(keys)
	if count == 0 {
		return a.ceiling
	}
	index := sort.SearchStrings(keys, key)
	if index >= count || keys[index] != key {
		return 0
	}
	base := a.ceiling / count
	remainder := a.ceiling % count
	if (index-a.rotation+count)%count < remainder {
		return base + 1
	}
	return base
}

func (m *admissionMember) heldCount() int {
	count := m.inFlight
	if m.live != nil {
		count += max(m.live(), 0)
	}
	return count
}
