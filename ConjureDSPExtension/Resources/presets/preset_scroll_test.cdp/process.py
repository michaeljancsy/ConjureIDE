def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count]
