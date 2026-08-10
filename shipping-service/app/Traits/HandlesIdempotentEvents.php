<?php

namespace App\Traits;

use App\Models\ProcessedEvent;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

trait HandlesIdempotentEvents
{
    /**
     * Executes the given callback idempotently by ensuring the event ID
     * has not been processed yet.
     */
    protected function handleIdempotentEvent(string $eventId, callable $callback): void
    {
        try {
            DB::transaction(function () use ($eventId, $callback) {
                ProcessedEvent::insert([
                    'event_id' => $eventId,
                    'processed_at' => now(),
                ]);

                $callback();
            });
        } catch (QueryException $e) {
            if ($e->errorInfo[0] === '23505' || str_contains($e->getMessage(), 'duplicate key')) {
                Log::warning("Duplicate event detected: {$eventId}. Skipping execution to maintain idempotency.");

                return;
            }
            throw $e;
        }
    }
}
