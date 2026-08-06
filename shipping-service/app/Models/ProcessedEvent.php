<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class ProcessedEvent extends Model
{
    public $timestamps = false;
    public $incrementing = false;
    protected $primaryKey = 'event_id';
    protected $keyType = 'string';

    protected $fillable = [
        'event_id',
        'processed_at',
    ];

    protected $casts = [
        'processed_at' => 'datetime',
    ];
}
