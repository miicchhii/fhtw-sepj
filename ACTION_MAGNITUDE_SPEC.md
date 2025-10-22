# Action Magnitude Specification

## Overview

The continuous action space uses magnitude-normalized movement where the action vector's direction determines movement direction and its magnitude determines what fraction of a full step to take.

**Implementation**: `game/scripts/core/Game.gd:610-626`

---

## Action Interpretation

### Input Format
```python
action = [dx, dy]  # Range: [-1, 1] for each component
```

### Processing Algorithm
```gdscript
1. action_vector = Vector2(dx, dy)
2. action_magnitude = action_vector.length()  # sqrt(dx² + dy²)
3. direction = action_vector.normalized()     # Unit vector
4. step_fraction = min(action_magnitude, 1.0) # Clamp to max 100%
5. move_offset = direction * (step_fraction * stepsize)
```

Where `stepsize = 200 pixels` (maximum movement distance per AI step)

---

## Example Actions

### Cardinal Directions (Full Steps)

| Action | Magnitude | Direction | Step Fraction | Distance | Result |
|--------|-----------|-----------|---------------|----------|--------|
| `[1.0, 0.0]` | 1.0 | East (→) | 100% | 200px | Full step east |
| `[0.0, 1.0]` | 1.0 | North (↑) | 100% | 200px | Full step north |
| `[-1.0, 0.0]` | 1.0 | West (←) | 100% | 200px | Full step west |
| `[0.0, -1.0]` | 1.0 | South (↓) | 100% | 200px | Full step south |

### Diagonal Directions (Full Steps)

| Action | Magnitude | Direction | Step Fraction | Distance | Result |
|--------|-----------|-----------|---------------|----------|--------|
| `[1.0, 1.0]` | 1.414 | NE (↗) | **100%** (clamped) | 200px | **Full step** northeast |
| `[1.0, -1.0]` | 1.414 | SE (↘) | **100%** (clamped) | 200px | **Full step** southeast |
| `[-1.0, 1.0]` | 1.414 | NW (↖) | **100%** (clamped) | 200px | **Full step** northwest |
| `[-1.0, -1.0]` | 1.414 | SW (↙) | **100%** (clamped) | 200px | **Full step** southwest |

**Key Point**: Diagonal actions `[±1, ±1]` have magnitude 1.414, which gets **clamped to 1.0**, ensuring equal movement distance in all directions.

### Partial Steps

| Action | Magnitude | Direction | Step Fraction | Distance | Result |
|--------|-----------|-----------|---------------|----------|--------|
| `[0.5, 0.0]` | 0.5 | East | 50% | 100px | Half step east |
| `[0.5, 0.5]` | 0.707 | NE | 71% | 141px | 71% step northeast |
| `[0.1, 0.0]` | 0.1 | East | 10% | 20px | Tiny step east |
| `[0.0, 0.0]` | 0.0 | N/A | 0% | 0px | No movement |

### Edge Cases

| Action | Magnitude | Direction | Step Fraction | Distance | Result |
|--------|-----------|-----------|---------------|----------|--------|
| `[2.0, 0.0]` | 2.0 | East | **100%** (clamped) | 200px | Full step (clamped) |
| `[0.001, 0.001]` | 0.0014 | NE | ~0% | ~0.3px | Negligible movement |

---

## Behavior Comparison: Before vs After

### Before (Direct Scaling - WRONG)
```gdscript
# Old code (deleted):
move_offset = Vector2(dx * stepsize, dy * stepsize)
```

| Action | Offset | Distance | Issue |
|--------|--------|----------|-------|
| `[1.0, 0.0]` | `[200, 0]` | **200px** | ✅ Correct |
| `[0.0, 1.0]` | `[0, 200]` | **200px** | ✅ Correct |
| `[1.0, 1.0]` | `[200, 200]` | **283px** | ❌ 41% longer! |
| `[0.5, 0.5]` | `[100, 100]` | **141px** | ❌ Inconsistent |

**Problem**: Diagonal movements were significantly longer than cardinal movements.

### After (Magnitude-Normalized - CORRECT)
```gdscript
# New code:
direction = action_vector.normalized()
step_fraction = min(action_magnitude, 1.0)
move_offset = direction * (step_fraction * stepsize)
```

| Action | Offset | Distance | Result |
|--------|--------|----------|--------|
| `[1.0, 0.0]` | `[200, 0]` | **200px** | ✅ Full step |
| `[0.0, 1.0]` | `[0, 200]` | **200px** | ✅ Full step |
| `[1.0, 1.0]` | `[141, 141]` | **200px** | ✅ Full step (normalized!) |
| `[0.5, 0.5]` | `[71, 71]` | **100px** | ✅ Half step |

**Result**: All full-magnitude actions move the same distance (200px), regardless of direction.

---

## Movement Distance Control

### By Unit Speed (Over One AI Step)

**AI step interval**: 0.25 seconds (15 physics ticks @ 60 FPS)

| Unit Type | Speed | Full Step (100%) | Half Step (50%) | Can Stop Before Next Action? |
|-----------|-------|------------------|-----------------|------------------------------|
| Infantry | 150 px/s | 200px target | 100px target | ✅ Yes (moves 37.5px in 0.25s) |
| Sniper | 60 px/s | 200px target | 100px target | ✅ Yes (moves 15px in 0.25s) |

### Practical Movement Ranges

**To stop before next AI action arrives** (unit reaches target):

| Unit | Speed | Max Action Magnitude | Max Target Distance |
|------|-------|---------------------|---------------------|
| Infantry | 150 | ~0.19 | ~38px |
| Sniper | 60 | ~0.08 | ~15px |

**For continuous movement** (target not reached before next action):
- Any magnitude ≥ 0.2 for Infantry
- Any magnitude ≥ 0.09 for Sniper

---

## AI Learning Implications

### Speed Control Options

1. **Sprint** (magnitude ≥ 0.5):
   - Unit moves continuously toward target
   - New actions arrive before reaching target
   - Smooth, fast movement

2. **Careful Approach** (magnitude 0.1-0.2):
   - Infantry can stop between actions
   - Snipers move continuously
   - Useful for precise positioning

3. **Inch Forward** (magnitude < 0.1):
   - Both unit types can stop between actions
   - Very precise control
   - Good for final positioning

4. **Stop** (magnitude ≈ 0.0):
   - Minimal or no movement
   - Unit holds position

### Strategic Depth

✅ **Full directional control**: AI can move in any direction, not just 8 discrete angles
✅ **Speed modulation**: AI can control how aggressively to move
✅ **Position-invariant**: Works identically regardless of map position
✅ **Fair diagonal movement**: No advantage to moving diagonally vs cardinal

---

## PPO Training Considerations

### Action Space Bounds
```python
action_space = Box(low=-1.0, high=1.0, shape=(2,), dtype=np.float32)
```

### Expected Output Distribution
- **Early training**: Random actions, uniform distribution
- **Mid training**: Clustering around cardinal/diagonal directions
- **Late training**: Fine-tuned magnitudes for tactical situations

### Potential Issues
1. **Action saturation**: If AI always outputs `[±1.0, ±1.0]`, it's not learning speed control
2. **Zero actions**: If AI outputs `[0, 0]` often, units won't move (check rewards)
3. **Magnitude collapse**: If all actions have magnitude < 0.1, movements too small

### Monitoring Recommendations
- Track action magnitude distribution per policy
- Log mean/std of action magnitude over time
- Visualize action direction histograms

---

## Implementation Notes

### Clamping Behavior
```gdscript
step_fraction = min(action_magnitude, 1.0)
```

**Why clamp?** Actions `[2.0, 0.0]` or `[1.5, 1.5]` (outside Box bounds, but possible due to numerical errors) get clamped to full step, preventing exploits.

### Zero-Movement Threshold
```gdscript
if action_magnitude > 0.01:  # Avoid division by zero
```

**Why 0.01?** Actions with magnitude < 0.01 result in <2 pixel movement (negligible), so treat as "no movement" to avoid division by zero in normalization.

### Direction Change Rewards
After target calculation, the direction change reward is computed using the **target direction**, not the raw action:

```gdscript
var new_direction = (new_target - u.global_position).normalized()
```

This means:
- Actions resulting in similar targets → similar directions → reward
- Actions with same magnitude but different direction → different directions → penalty

---

## Testing Checklist

- [ ] Action `[1.0, 0.0]` moves same distance as `[0.0, 1.0]`
- [ ] Action `[1.0, 1.0]` moves same distance as `[1.0, 0.0]` (200px both)
- [ ] Action `[0.5, 0.0]` moves half the distance of `[1.0, 0.0]` (100px vs 200px)
- [ ] Action `[0.0, 0.0]` results in no movement
- [ ] Action `[2.0, 0.0]` gets clamped to `[1.0, 0.0]` behavior
- [ ] Small actions `[0.05, 0.05]` allow units to stop before next action
- [ ] Direction change rewards work correctly with normalized actions

---

## Related Files

- **Implementation**: `game/scripts/core/Game.gd:610-626`
- **Python Action Space**: `ai/godot_multi_env.py:63`
- **Documentation**: `CLAUDE.md` (Training Parameters section)

---

## Changelog

**2025-10-21**: Implemented magnitude-normalized action interpretation
- Changed from direct scaling to normalize-then-scale approach
- Ensures equal movement distance for all full-magnitude actions
- Diagonal movements no longer 41% longer than cardinal movements
