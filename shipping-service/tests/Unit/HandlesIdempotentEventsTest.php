<?php

namespace Tests\Unit;

use App\Models\ProcessedEvent;
use App\Traits\HandlesIdempotentEvents;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class HandlesIdempotentEventsTest extends TestCase
{
    use RefreshDatabase;

    public function test_executes_callback_when_event_is_new()
    {
        $class = new class
        {
            use HandlesIdempotentEvents;

            public function process($eventId, $callback)
            {
                $this->handleIdempotentEvent($eventId, $callback);
            }
        };

        $executed = false;
        $class->process('test-event-1', function () use (&$executed) {
            $executed = true;
        });

        $this->assertTrue($executed);
        $this->assertDatabaseHas('processed_events', [
            'event_id' => 'test-event-1',
        ]);
    }

    public function test_skips_callback_when_event_is_duplicate()
    {
        ProcessedEvent::insert([
            'event_id' => 'test-event-2',
            'processed_at' => now(),
        ]);

        $class = new class
        {
            use HandlesIdempotentEvents;

            public function process($eventId, $callback)
            {
                $this->handleIdempotentEvent($eventId, $callback);
            }
        };

        $executed = false;
        $class->process('test-event-2', function () use (&$executed) {
            $executed = true;
        });

        $this->assertFalse($executed);
    }
}
