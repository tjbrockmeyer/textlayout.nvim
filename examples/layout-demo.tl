A line break joins lines; a > at the start of a line opens the next one.

Left | Middle | Right
> one  | two    | three

A pipe makes that line a row of columns.
Brackets open a layer deeper; the new layer stacks.

[alpha
> beta
> gamma] | next to the stack

Groups sit inline in a sentence: status is [OK].

@grid [
Name | Class  | Level
> Bob  | Wizard | 12
]

A layer stacks; write @row to make it flow instead.

@row [Left | Right
>      one  | two]
