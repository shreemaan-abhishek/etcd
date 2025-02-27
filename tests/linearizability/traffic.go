// Copyright 2022 The etcd Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package linearizability

import (
	"context"
	"fmt"
	"math/rand"
	"time"

	"golang.org/x/time/rate"
)

var (
	DefaultTraffic Traffic = readWriteSingleKey{key: "key", writes: []opChance{{operation: Put, chance: 100}}}
)

type Traffic interface {
	Run(ctx context.Context, c *recordingClient, limiter *rate.Limiter)
}

type readWriteSingleKey struct {
	key    string
	writes []opChance
}

type opChance struct {
	operation Operation
	chance    int
}

func (t readWriteSingleKey) Run(ctx context.Context, c *recordingClient, limiter *rate.Limiter) {
	maxOperationsPerClient := 1000000
	minId := maxOperationsPerClient * c.id
	maxId := maxOperationsPerClient * (c.id + 1)

	for writeId := minId; writeId < maxId; {
		select {
		case <-ctx.Done():
			return
		default:
		}
		// Execute one read per one write to avoid operation history include too many failed writes when etcd is down.
		err := t.Read(ctx, c, limiter)
		if err != nil {
			continue
		}
		// Provide each write with unique id to make it easier to validate operation history.
		t.Write(ctx, c, limiter, writeId)
		writeId++
	}
	return
}

func (t readWriteSingleKey) Read(ctx context.Context, c *recordingClient, limiter *rate.Limiter) error {
	getCtx, cancel := context.WithTimeout(ctx, 20*time.Millisecond)
	err := c.Get(getCtx, t.key)
	cancel()
	if err == nil {
		limiter.Wait(ctx)
	}
	return err
}

func (t readWriteSingleKey) Write(ctx context.Context, c *recordingClient, limiter *rate.Limiter, id int) error {
	putCtx, cancel := context.WithTimeout(ctx, 20*time.Millisecond)

	var err error
	switch t.pickWriteOperation() {
	case Put:
		err = c.Put(putCtx, t.key, fmt.Sprintf("%d", id))
	default:
		panic("invalid operation")
	}
	cancel()
	if err == nil {
		limiter.Wait(ctx)
	}
	return err
}

func (t readWriteSingleKey) pickWriteOperation() Operation {
	sum := 0
	for _, op := range t.writes {
		sum += op.chance
	}
	roll := rand.Int() % sum
	for _, op := range t.writes {
		if roll < op.chance {
			return op.operation
		}
		roll -= op.chance
	}
	panic("unexpected")
}
