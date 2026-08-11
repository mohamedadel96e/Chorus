CREATE TABLE event_trace (
    id UUID PRIMARY KEY,
    correlation_id VARCHAR(255) NOT NULL,
    event_id UUID NOT NULL,
    event_type VARCHAR(255) NOT NULL,
    payload JSONB NOT NULL,
    occurred_at TIMESTAMP NOT NULL,
    recorded_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_event_trace_correlation_id ON event_trace (correlation_id);
CREATE INDEX idx_event_trace_occurred_at ON event_trace (occurred_at);
