const { login } = require('./auth');
test('login', () => expect(login('admin', 'hunter2')).toBe(true));
