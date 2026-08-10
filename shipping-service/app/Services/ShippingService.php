<?php

namespace App\Services;

use App\Models\OutboxEvent;
use App\Models\Shipment;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;

class ShippingService
{
    public function createShipment(array $payload, string $correlationId): void
    {
        $orderId = $payload['order_id'];

        DB::transaction(function () use ($orderId, $correlationId) {
            $trackingNumber = 'TRK-'.strtoupper(substr(md5($orderId), 0, 8));

            $shipment = Shipment::create([
                'order_id' => $orderId,
                'address' => '123 Mock Address',
                'status' => 'CREATED',
                'tracking_number' => $trackingNumber,
            ]);

            OutboxEvent::create([
                'id' => (string) Str::uuid(),
                'event_type' => 'ShipmentCreated',
                'routing_key' => 'shipment.created',
                'correlation_id' => $correlationId,
                'payload' => [
                    'order_id' => $orderId,
                    'shipment_id' => "ship-{$shipment->id}",
                    'tracking_number' => $trackingNumber,
                    'estimated_delivery' => date('Y-m-d', strtotime('+3 days')),
                ],
                'status' => 'PENDING',
                'occurred_at' => now(),
            ]);

            Log::info("Shipment created for order {$orderId} with tracking {$trackingNumber}");
        });
    }
}
