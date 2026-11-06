"""Synthetic crop-only graph for simulator plumbing tests, never a denoiser."""
from pathlib import Path
import onnx
from onnx import helper as h, TensorProto as T
nodes = [h.make_node('Slice', ['input', 'starts', 'ends', 'axes'], ['output'])]
constants = [h.make_tensor(name, T.INT64, [2], values) for name, values in
             [('starts', [112, 112]), ('ends', [400, 400]), ('axes', [2, 3])]]
graph = h.make_graph(nodes, 'synthetic-central-crop',
    [h.make_tensor_value_info('input', T.FLOAT, [1, 3, 512, 512])],
    [h.make_tensor_value_info('output', T.FLOAT, [1, 3, 288, 288])], constants)
model = h.make_model(graph, opset_imports=[h.make_opsetid('', 17)], ir_version=9)
onnx.checker.check_model(model)
onnx.save(model, Path('Models/local-linear.onnx'))
