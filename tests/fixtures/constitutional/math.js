/**
 * Add two numbers
 * @precondition a is a number
 * @precondition b is a number
 * @postcondition result equals a + b
 * @invariant typeof result === 'number'
 */
function add(a, b) {
  if (a === null || a === undefined || b === null || b === undefined) return 0;
  return a + b;
}

/**
 * Divide two numbers
 * @precondition divisor \!== 0
 * @postcondition result equals dividend / divisor
 */
function divide(dividend, divisor) {
  if (divisor === 0) throw new Error("Division by zero");
  return dividend / divisor;
}

module.exports = { add, divide };
// updated
