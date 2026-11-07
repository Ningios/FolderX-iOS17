#!/usr/bin/env python3
"""Source-level geometry regression examples from actual v8 trace (not on-device validation)."""
from dataclasses import dataclass
@dataclass
class Rect:
    x:float;y:float;w:float;h:float

def intersection(a,b):
    dx=max(0,min(a.x+a.w,b.x+b.w)-max(a.x,b.x))
    dy=max(0,min(a.y+a.h,b.y+b.h)-max(a.y,b.y))
    return dx*dy

def would_block(original,proposed,folder,model_stable=True,valid_folder=True):
    if not model_stable or not valid_folder:return False
    area=proposed.w*proposed.h
    return intersection(proposed,folder)>0.58*area and intersection(original,folder)<0.08*area

wide_top=Rect(27.3,90,338,158)
tests=[
    (Rect(302,580,60,74),Rect(121.3,188,60,74)),
    (Rect(211.7,482,60,74),Rect(302,90,60,74)),
    (Rect(302,482,60,74),Rect(31,188,60,74)),
]
for original,wrong in tests:assert would_block(original,wrong,wide_top),(original,wrong)
assert not would_block(tests[0][0],Rect(302,482,60,74),wide_top)
assert not would_block(*tests[0],wide_top,model_stable=False)
assert not would_block(*tests[0],wide_top,valid_folder=False)
assert not would_block(tests[0][0],tests[0][0],wide_top)
print('PASS v8 regression: 3 invalid view moves rejected, legitimate free-cell/committed-model movement allowed; no folder frame mutation')

# Folder-source v9: four model-stable ordinary App views jumped upward while
# three expanded folder models retained their original ranges.
v9=[
 (Rect(302,580,60,74),Rect(121.3,188,60,74)),
 (Rect(211.7,482,60,74),Rect(211.7,90,60,74)),
 (Rect(302,482,60,74),Rect(302,90,60,74)),
 (Rect(211.7,580,60,74),Rect(31,188,60,74)),
]
for original,wrong in v9:assert would_block(original,wrong,wide_top),(original,wrong)
print('PASS v9 folder-drag regression: four model-stable App jumps would be rejected')
