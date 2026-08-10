<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Str;
use Tests\TestCase;

class ShippingControllerTest extends TestCase
{
    use RefreshDatabase;

    public function test_schedule_endpoint()
    {
        $orderId = (string) Str::uuid();
        $payload = [
            'orderId' => $orderId,
            'address' => '123 Test St',
        ];

        $response = $this->postJson('/api/shipping/schedule', $payload);

        $response->assertStatus(201)
            ->assertJsonPath('status', 'SCHEDULED')
            ->assertJsonStructure(['shipment_id', 'status', 'message']);

        $this->assertDatabaseHas('shipments', [
            'order_id' => $orderId,
            'status' => 'SCHEDULED',
        ]);
    }
}
