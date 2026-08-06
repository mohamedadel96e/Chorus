<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\Api\ShippingController;

Route::post('/shipping/schedule', [ShippingController::class, 'schedule']);
