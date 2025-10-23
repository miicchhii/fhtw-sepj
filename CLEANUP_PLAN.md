# Code Cleanup & Refactoring Plan

## Executive Summary

This document identifies technical debt, organizational issues, and cleanup opportunities in the RTS AI training codebase. Issues are categorized by severity and sorted by file/component.

---

## Critical Issues (High Priority)

### 1. **Game.gd - God Object Anti-Pattern** ⚠️ SEVERE

**File**: `game/scripts/core/Game.gd` (736 lines)

**Problem**: Single massive class handling 8+ different responsibilities

**Current Responsibilities**:
1. Episode management (reset, episode counting)
2. Unit spawning logic
3. Base spawning logic
4. Observation building (94-dim vector construction)
5. Reward calculation (11 different reward components)
6. Action application (movement command processing)
7. Physics processing loop
8. Player input handling (unit selection, area selection)
9. Unit tracking and management

**Issues**:
- Violates Single Responsibility Principle
- Hard to test individual components
- Difficult to understand and maintain
- Changes to one feature risk breaking others
- ~736 lines in single file

**Recommended Refactoring**:

```
game/scripts/core/
├── Game.gd (coordinator only, ~100 lines)
├── EpisodeManager.gd (reset, counting, side alternation)
├── SpawnManager.gd (unit + base spawning logic)
├── ObservationBuilder.gd (build 94-dim vectors)
├── RewardCalculator.gd (all reward logic centralized)
├── ActionHandler.gd (apply actions from AI)
└── PlayerController.gd (selection, manual control)
```

**Benefits**:
- Each class has single clear purpose
- Testable in isolation
- Easier to modify reward structure
- Clearer separation of AI vs player logic

**Effort**: 6-8 hours

---

### 2. **RTSUnit.gd - Mixed Concerns** ⚠️ HIGH

**File**: `game/scripts/units/RTSUnit.gd` (367 lines)

**Problem**: Mixing combat logic, UI, AI visualization, and movement

**Current Responsibilities**:
1. Combat system (attack targeting, damage dealing)
2. Movement physics
3. Player input handling (selection, right-click)
4. Debug visualization (POI lines, attack range circles)
5. Combat stat tracking (for rewards)
6. Policy assignment
7. Auto-attack logic for BOTH allies AND enemies (duplicated code)

**Issues**:
- Duplicated auto-attack logic (lines 226-243 vs 262-291)
- UI/debug code mixed with game logic
- Player input in unit class (should be in controller)
- Hard to disable visualization for headless training

**Recommended Refactoring**:

```
game/scripts/units/
├── RTSUnit.gd (core unit data + movement only, ~100 lines)
├── CombatSystem.gd (attack targeting, damage, cooldowns)
├── UnitDebugVisualizer.gd (POI lines, attack circles)
└── UnitInputHandler.gd (selection, player control)
```

**Specific Cleanup**:
```gdscript
# BAD (current): Duplicated attack logic
if not is_enemy:
    # 20 lines of auto-attack logic
if is_enemy:
    # 20 lines of same auto-attack logic (just flipped ally/enemy)

# GOOD (refactored):
class CombatSystem:
    func auto_attack(attacker: RTSUnit, target_group: String):
        # Single implementation, parameterized by target group
```

**Effort**: 4-5 hours

---

### 3. **godot_multi_env.py - Monolithic Environment** ⚠️ HIGH

**File**: `ai/godot_multi_env.py` (567 lines)

**Problem**: Mixing connection management, observation processing, and environment logic

**Current Responsibilities**:
1. TCP socket connection management
2. Message serialization/deserialization
3. Observation extraction and normalization
4. Action packaging
5. Reward/done processing
6. Agent lifecycle management
7. Dead agent handling

**Recommended Refactoring**:

```python
ai/
├── godot_multi_env.py (main env class, ~150 lines)
├── godot_connection.py (TCP socket + JSON protocol)
├── observation_processor.py (extract & normalize observations)
├── agent_manager.py (track agents, handle deaths)
└── reward_processor.py (extract rewards from Godot messages)
```

**Benefits**:
- Easier to add new observation features
- Connection logic reusable for other envs
- Testable normalization in isolation
- Clearer error handling

**Effort**: 5-6 hours

---

## Medium Priority Issues

### 4. **Dead Code / Unused Files** ⚠️ MEDIUM

**Files to Remove or Archive**:

```
game/scripts/units/
├── Unit1.gd              # Old unit implementation (superseded by RTSUnit)
├── pawn.gd               # Unused unit class

game/scripts/buildings/
├── coin_house.gd         # Not used in AI training
├── robo_shop.gd          # Not used in AI training
├── ressource.gd          # Typo in name, likely unused

game/scripts/global/
├── POP.gd                # Unknown purpose, check usage
├── spawn_unit.gd         # Might overlap with Global.spawnUnit
```

**Action**:
1. Search for references to each file
2. If no references in active code paths: move to `_archived/` folder
3. Document why archived (in commit message)

**Effort**: 1-2 hours

---

### 5. **Magic Numbers** ⚠️ MEDIUM

**Scattered throughout codebase**:

```gdscript
# Game.gd
var stepsize: float = 200.0  # Why 200? Should be named constant
var margin_x = 150           # What does 150 represent?
var spawn_spacing_x = 250/1  # Why divide by 1?

# godot_multi_env.py
stepsize = 200               # Duplicated from Godot
max_speed = 100.0            # Should match unit max speed
norm_attack_range = attack_range / 200.0  # Why 200?
```

**Recommended**:

```gdscript
# game/scripts/core/GameConfig.gd (new file)
class_name GameConfig

const AI_ACTION_STEPSIZE: float = 200.0       # Max movement distance per AI step
const BASE_SPAWN_MARGIN: float = 150.0        # Safe distance from map edges
const MAX_EXPECTED_ATTACK_RANGE: float = 200.0
const MAX_EXPECTED_SPEED: float = 100.0
const UNIT_SPAWN_SPACING: float = 250.0
```

**Effort**: 2-3 hours

---

### 6. **Inconsistent Naming Conventions** ⚠️ MEDIUM

**Issues**:

```gdscript
# Mixed case in same file:
var ai_step: int           # snake_case
var Speed := 50            # PascalCase (should be lowercase)
var _atk_cd := 0.0         # abbreviated

# Inconsistent abbreviations:
var hp                     # abbreviated
var attack_cooldown        # full word
var _atk_cd                # abbreviated differently
var max_hp                 # mixed

# Boolean naming:
var is_enemy               # Good (verb prefix)
var selected               # Bad (should be is_selected)
```

**Recommended Standards**:
- Variables: `snake_case`
- Constants: `SCREAMING_SNAKE_CASE`
- Classes: `PascalCase`
- Booleans: `is_`, `has_`, `should_` prefix
- Private: `_` prefix
- No abbreviations unless extremely common (hp, id ok)

**Effort**: 3-4 hours (semi-automated with regex)

---

### 7. **Duplicate Logic in Python and GDScript** ⚠️ MEDIUM

**Observation normalization duplicated**:

```python
# godot_multi_env.py
norm_attack_range = attack_range / 200.0
norm_speed = speed / 100.0
```

```gdscript
# Game.gd observation builder (future if we calculate in Godot)
# Could have same normalization logic
```

**Action scaling duplicated**:

```python
# godot_multi_env.py (removed, but was there)
stepsize = 200
```

```gdscript
# Game.gd
var stepsize: float = 200.0
```

**Recommendation**:
- Define constants in **single source of truth**
- Pass via initial handshake message from Godot → Python
- Python reads map dimensions, action scale, etc. from Godot on reset

**Effort**: 2-3 hours

---

## Low Priority / Polish

### 8. **Missing Type Hints (GDScript)** ⚠️ LOW

**Examples**:
```gdscript
var units = []                    # Should be: var units: Array[RTSUnit] = []
var poi_positions: Array = []     # Should be: Array[Vector2]
func _get_unit(id: String):       # Should specify return type → RTSUnit
```

**Benefit**: Better IDE autocomplete, catch type errors at edit time

**Effort**: 2 hours

---

### 9. **Inconsistent Error Handling** ⚠️ LOW

**Issues**:
- Some functions use `assert()`, others `print()`, others silent fail
- No consistent logging strategy
- Hard to debug connection issues

**Example**:
```python
# Some places:
if not connected:
    raise RuntimeError("Not connected")

# Other places:
if not connected:
    print("Connection lost")
    return None

# Other places:
if not connected:
    if not self._connect():
        # Try to recover silently
```

**Recommendation**: Unified error handling strategy with log levels

**Effort**: 3 hours

---

### 10. **Long Functions** ⚠️ LOW

**Functions exceeding 50 lines** (hard to understand):

```
Game.gd:
- _physics_process()      : 132 lines (reward calculation embedded)
- _build_observation()    : 97 lines
- spawn_all_units()       : 54 lines

RTSUnit.gd:
- _physics_process()      : 92 lines (movement + combat logic)

godot_multi_env.py:
- _extract_obs_and_agents(): 145 lines
- step()                  : 154 lines
```

**Recommendation**: Extract helper methods, aim for <30 lines per function

**Effort**: 4-5 hours

---

## Organizational Issues

### 11. **Unclear File Structure** ⚠️ LOW

**Current**:
```
game/scripts/
├── ai/           # Only AiServer
├── buildings/    # Mix of active + dead code
├── core/         # Only Game.gd
├── global/       # Singletons, unclear naming
├── ui/           # UI + camera
└── units/        # Mix of base + implementations + dead code
```

**Recommended**:
```
game/scripts/
├── ai/
│   ├── AiServer.gd
│   ├── ObservationBuilder.gd
│   ├── ActionHandler.gd
│   └── RewardCalculator.gd
├── core/
│   ├── Game.gd (coordinator)
│   ├── EpisodeManager.gd
│   └── SpawnManager.gd
├── entities/
│   ├── units/
│   │   ├── RTSUnit.gd (base)
│   │   ├── Infantry.gd
│   │   ├── Sniper.gd
│   │   └── CombatSystem.gd
│   └── buildings/
│       └── Base.gd
├── player/
│   ├── PlayerController.gd
│   └── SelectionManager.gd
├── singletons/  # Rename from "global"
│   └── Global.gd
└── ui/
    ├── camera.gd
    └── MiniMap.gd
```

**Effort**: 1 hour (mostly file moves)

---

### 12. **Global Singleton vs Static Functions** ⚠️ LOW

**Current**: `Global.gd` is autoloaded singleton for unit spawning

**Question**: Does this need to be a singleton, or could it be static functions in a namespace?

```gdscript
# Current:
Global.spawnUnit(pos, is_enemy, unit_type)

# Alternative (static class):
class_name UnitFactory
static func spawn_unit(pos, is_enemy, unit_type):
    # No singleton needed, just static methods
```

**Benefit**: Easier to test, no hidden global state

**Effort**: 2 hours

---

## Summary Table

| Issue | Severity | Effort | Impact | Priority |
|-------|----------|--------|--------|----------|
| Game.gd God Object | Critical | 6-8h | High | 1 |
| RTSUnit mixed concerns | High | 4-5h | High | 2 |
| godot_multi_env.py monolithic | High | 5-6h | Medium | 3 |
| Dead code removal | Medium | 1-2h | Low | 4 |
| Magic numbers | Medium | 2-3h | Medium | 5 |
| Duplicate Python/Godot logic | Medium | 2-3h | Medium | 6 |
| Inconsistent naming | Medium | 3-4h | Low | 7 |
| Missing type hints | Low | 2h | Low | 8 |
| Long functions | Low | 4-5h | Medium | 9 |
| Error handling consistency | Low | 3h | Low | 10 |
| File structure | Low | 1h | Low | 11 |
| Global singleton pattern | Low | 2h | Low | 12 |
| **TOTAL** | | **35-48h** | | |

---

## Recommended Phased Approach

### Phase 1: Quick Wins (4-5 hours)
1. Remove dead code (#4)
2. Reorganize file structure (#11)
3. Extract magic numbers to constants (#5)

**Benefit**: Cleaner codebase, easier to navigate

### Phase 2: Separate Concerns (15-19 hours)
1. Refactor Game.gd into separate managers (#1)
2. Refactor RTSUnit.gd combat/UI separation (#2)
3. Refactor godot_multi_env.py (#3)

**Benefit**: Easier to modify and test individual systems

### Phase 3: Polish (16-24 hours)
1. Fix naming conventions (#6, #7)
2. Add type hints (#8)
3. Improve error handling (#9)
4. Split long functions (#10)
5. Consider singleton alternatives (#12)

**Benefit**: Better code quality, fewer bugs

---

## Critical Path for Continued Development

**Before adding new features** (like reward dashboard), recommend completing **Phase 1 + items #1 and #5 from Phase 2**:

1. Remove dead code
2. Refactor Game.gd (especially extract RewardCalculator)
3. Extract magic numbers

**Why**: These changes will make implementing reward tracking much cleaner (dedicated RewardCalculator class with clear constants).

---

## Next Steps

1. Review and prioritize this list
2. Choose phase to start with
3. Create feature branch for refactoring
4. Implement changes incrementally
5. Test after each refactor
6. Merge when tests pass

Would you like me to start with any specific item from this list?
