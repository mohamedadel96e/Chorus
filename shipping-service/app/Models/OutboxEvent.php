<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class OutboxEvent extends Model
{
    public $timestamps = false;
    public $incrementing = false;
    protected $keyType = 'string';

    protected $fillable = [
        'id',
        'event_type',
        'routing_key',
        'correlation_id',
        'payload',
        'occurred_at',
        'status',
    ];

    protected $casts = [
        'payload' => 'array',
        'occurred_at' => 'datetime',
    ];
}
