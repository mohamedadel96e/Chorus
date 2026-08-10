<?php

namespace Tests\Unit;

use App\Services\ShippingService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Str;
use Tests\TestCase;

class ShippingServiceTest extends TestCase
{
    use RefreshDatabase;

    public function test_schedule_creates_shipment_and_outbox_event()
    {
        $service = new ShippingService;
        $orderId = (string) Str::uuid();
        $address = '123 Test St';

        $result = $service->schedule($orderId, $address);

        $this->assertEquals('SCHEDULED', $result['status']);
        $this->assertNotNull($result['shipment_id']);

        $this->assertDatabaseHas('shipments', [
            'id' => $result['shipment_id'],
            'order_id' => $orderId,
            'address' => $address,
            'status' => 'SCHEDULED',
        ]);

        $this->assertDatabaseHas('outbox_events', [
            'correlation_id' => $orderId,
            'event_type' => 'ShippingScheduled',
            'status' => 'PENDING',
        ]);
    }
}
