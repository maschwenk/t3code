import * as Schema from "effect/Schema";

// Its own module so the computer-use worker can validate goal steps without loading the decider.
export const GoalInput = Schema.Struct({
  goal: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(1000)),
  maxSteps: Schema.optional(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 30 }))),
  // Lower it for low-stakes picks where several options are fine, such as a game move.
  minConfidence: Schema.optional(
    Schema.Number.check(Schema.isBetween({ minimum: 0.1, maximum: 0.95 })),
  ),
  deny: Schema.optional(
    Schema.Array(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100))).check(
      Schema.isMaxLength(50),
    ),
  ),
});
export type GoalInput = typeof GoalInput.Type;
