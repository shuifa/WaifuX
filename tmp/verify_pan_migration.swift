#!/usr/bin/env swift
import Foundation
// 验证迁移公式：[-1,1] → [0,1]，0→0.5
func migrate(_ old: Double) -> Double { old/2 + 0.5 }
assert(migrate(-1) == 0, "迁移 -1 应为 0")
assert(migrate(0) == 0.5, "迁移 0 应为 0.5")
assert(migrate(1) == 1, "迁移 1 应为 1")
assert(migrate(0.6) == 0.8, "迁移 0.6 应为 0.8")
print("pan 迁移公式验证通过")