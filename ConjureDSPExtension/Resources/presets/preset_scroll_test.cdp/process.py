def process(ctx):
    n_ch = ctx.inputs.shape[0]
    for ch in range(n_ch):
        ctx.outputs[ch] = ctx.inputs[ch]
