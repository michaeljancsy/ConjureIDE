def process(ctx):
    for ch in range(len(ctx.inputs)):
        ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count]
