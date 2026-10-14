// This file violates architecture rules
const serviceA = require('./service-a');
const serviceB = require('./service-b');
serviceB.dependsOn(serviceA);
serviceA.dependsOn(serviceB); // VIOLATION: circular dependency
