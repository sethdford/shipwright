// WARNING: deliberate violations for constitutional testing
const password = "hunter2";
const api_key = "sk-1234567890";

function login(user, pass) {
  try {} catch(e) {}
  // TODO: fix this hack
  return user === "admin" && pass === password;
}

module.exports = { login };
