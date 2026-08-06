<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Services\ShippingService;
use Illuminate\Http\Request;
use Illuminate\Http\JsonResponse;
use Illuminate\Validation\ValidationException;

class ShippingController extends Controller
{
    protected ShippingService $shippingService;

    public function __construct(ShippingService $shippingService)
    {
        $this->shippingService = $shippingService;
    }

    public function schedule(Request $request): JsonResponse
    {
        try {
            $validated = $request->validate([
                'orderId' => 'required|uuid',
                'address' => 'required|string',
            ]);

            $result = $this->shippingService->schedule(
                $validated['orderId'],
                $validated['address']
            );

            return response()->json($result, 201);
        } catch (ValidationException $e) {
            return response()->json([
                'status' => 'FAILED',
                'message' => $e->getMessage(),
                'errors' => $e->errors(),
            ], 422);
        } catch (\Exception $e) {
            return response()->json([
                'status' => 'FAILED',
                'message' => $e->getMessage(),
            ], 400);
        }
    }
}
