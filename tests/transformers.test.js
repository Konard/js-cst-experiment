/* eslint-env jest */
const { transformCode: chev } =
  require('../src/chevrotainTransformer');
const { transformCode: tree } =
  require('../src/treeSitterTransformer');

const input = `function foo(a,b){ return a + b; }`;

describe('CST transformers', () => {
  test('Chevrotain injects instrumentation', () => {
    const out = chev(input);
    expect(out).toMatch(/let fooOutput;/);
    expect(out).toMatch(/console\.log\(fooOutput\)/);
    expect(out).toMatch(/return fooOutput;/);
  });

  test('Tree‑sitter injects instrumentation', () => {
    const out = tree(input);
    expect(out).toMatch(/let fooOutput;/);
    expect(out).toMatch(/console\.log\(fooOutput\)/);
    expect(out).toMatch(/return fooOutput;/);
  });

  test('Both implementations yield identical text', () => {
    expect(chev(input)).toBe(tree(input));
  });
});
