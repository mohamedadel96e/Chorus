<?php

use App\Http\Controllers\Api\ShippingController;
use Illuminate\Support\Facades\Route;

Route::post('/shipping/schedule', [ShippingController::class, 'schedule']);
