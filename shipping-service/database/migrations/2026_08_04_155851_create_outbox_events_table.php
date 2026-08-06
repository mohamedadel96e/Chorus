<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Run the migrations.
     */
    public function up(): void
    {
        Schema::create('outbox_events', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->string('event_type');
            $table->string('routing_key');
            $table->uuid('correlation_id');
            $table->jsonb('payload');
            $table->timestamp('occurred_at');
            $table->string('status')->index();
        });
    }

    /**
     * Reverse the migrations.
     */
    public function down(): void
    {
        Schema::dropIfExists('outbox_events');
    }
};
