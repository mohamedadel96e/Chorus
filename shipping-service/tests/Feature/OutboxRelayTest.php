<?php

namespace Tests\Feature;

use Carbon\Carbon;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Mockery;
use PhpAmqpLib\Channel\AMQPChannel;
use PhpAmqpLib\Connection\AMQPStreamConnection;
use Tests\TestCase;

class OutboxRelayTest extends TestCase
{
    use RefreshDatabase;

    public function test_it_relays_pending_events()
    {
        $id = (string) Str::uuid();

        DB::table('outbox_events')->insert([
            'id' => $id,
            'correlation_id' => (string) Str::uuid(),
            'event_type' => 'ShippingCreated',
            'routing_key' => 'shipping.created',
            'payload' => json_encode(['data' => 'test']),
            'occurred_at' => Carbon::now(),
            'status' => 'PENDING',
        ]);

        $mockConnection = Mockery::mock(AMQPStreamConnection::class);
        $mockChannel = Mockery::mock(AMQPChannel::class);

        $mockConnection->shouldReceive('channel')->andReturn($mockChannel);
        $mockChannel->shouldReceive('exchange_declare')->with('chorus.events', 'topic', false, true, false);
        $mockChannel->shouldReceive('basic_publish')->once();
        $mockChannel->shouldReceive('close');
        $mockConnection->shouldReceive('close');

        $this->app->instance(AMQPStreamConnection::class, $mockConnection);

        $this->artisan('outbox:relay')
            ->assertExitCode(0);

        $this->assertDatabaseHas('outbox_events', [
            'id' => $id,
            'status' => 'PUBLISHED',
        ]);
    }
}
