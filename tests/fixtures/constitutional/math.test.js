const { add, divide } = require('./math');
test('add', () => expect(add(1, 2)).toBe(3));
test('divide', () => expect(divide(10, 2)).toBe(5));
test('divide by zero', () => expect(() => divide(1, 0)).toThrow());
