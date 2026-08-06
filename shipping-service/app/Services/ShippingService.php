<?php

namespace App\Services;

use App\Models\Shipment;
use App\Models\OutboxEvent;
use Illuminate\Support\Facades\DB;
use Carbon\Carbon;

class ShippingService
{
    public function schedule(string $orderId, string $address): array
    {
        return DB::transaction(function () use ($orderId, $address) {
            $shipment = Shipment::create([
                'order_id' => $orderId,
                'address' => $address,
                'status' => 'SCHEDULED',
            ]);

            OutboxEvent::create([
                'id' => (string) \Illuminate\Support\Str::uuid(),
                'correlation_id' => $orderId,
                'event_type' => 'ShippingScheduled',
                'routing_key' => 'shipping.scheduled',
                'payload' => [
                    'shipment_id' => $shipment->id,
                    'order_id' => $orderId,
                    'status' => 'SCHEDULED',
                ],
                'occurred_at' => Carbon::now(),
                'status' => 'PENDING',
            ]);

            return [
                'shipment_id' => $shipment->id,
                'status' => $shipment->status,
                'message' => 'Shipment scheduled successfully',
            ];
        });
    }
}
