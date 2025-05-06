#!/usr/bin/env bash
# init_apply.sh — bootstrap / update repo with CST‑based transformers + tests
set -euo pipefail

SRC_DIR="src"
TEST_DIR="tests"

echo "─── 1.  🛠  Initialising Yarn project (if needed) ───────────────────────────"
if [[ ! -f package.json ]]; then
  yarn init -y >/dev/null
  # keep the default test script; we'll call jest directly
fi

echo "─── 2.  📦  Installing / updating dependencies ─────────────────────────────"
yarn add chevrotain tree-sitter tree-sitter-javascript >/dev/null
yarn add --dev jest >/dev/null

echo "─── 3.  📂  Writing source files ────────────────────────────────────────────"
mkdir -p "${SRC_DIR}" "${TEST_DIR}"

cat > "${SRC_DIR}/chevrotainTransformer.js" <<'CHEVROTAIN'
// chevrotainTransformer.js  (CommonJS)
// Instruments JS functions via a tiny Chevrotain CST
const { createToken, Lexer, CstParser } = require('chevrotain');

// ── Tokens ──────────────────────────────────────────────────────────────
const FunctionKw = createToken({ name: 'FunctionKw', pattern: /function/ });
const Identifier = createToken({ name: 'Identifier', pattern: /[a-zA-Z_$]\w*/ });
const LParen     = createToken({ name: 'LParen', pattern: /\(/ });
const RParen     = createToken({ name: 'RParen', pattern: /\)/ });
const LCurly     = createToken({ name: 'LCurly', pattern: /\{/ });
const RCurly     = createToken({ name: 'RCurly', pattern: /\}/ });
const ReturnKw   = createToken({ name: 'ReturnKw', pattern: /return/ });
const Semicolon  = createToken({ name: 'Semicolon', pattern: /;/ });
const WhiteSpace = createToken({ name: 'WhiteSpace', pattern: /\s+/, group: Lexer.SKIPPED });
const Other      = createToken({ name: 'Other', pattern: /[^{}();\s]+/ });

const allTokens = [
  WhiteSpace, FunctionKw, ReturnKw, Identifier,
  LParen, RParen, LCurly, RCurly, Semicolon, Other
];

const JsLexer = new Lexer(allTokens);

// ── Parser (just enough grammar) ─────────────────────────────────────────
class JsParser extends CstParser {
  constructor() {
    super(allTokens);
    const $ = this;
    $.RULE('program', () => $.MANY(() => $.SUBRULE($.functionDecl)));
    $.RULE('functionDecl', () => {
      $.CONSUME(FunctionKw);
      $.CONSUME(Identifier, { LABEL: 'name' });
      $.CONSUME(LParen); $.CONSUME(RParen);
      $.CONSUME(LCurly, { LABEL: 'lcurly' });
      $.MANY(() => $.SUBRULE($.returnStmt));
      $.CONSUME(RCurly, { LABEL: 'rcurly' });
    });
    $.RULE('returnStmt', () => {
      $.CONSUME(ReturnKw);
      $.CONSUME(Other, { LABEL: 'expr' });
      $.CONSUME(Semicolon);
    });
    this.performSelfAnalysis();
  }
}
const parser = new JsParser();

// ── Transformer ─────────────────────────────────────────────────────────
function transformCode(source) {
  const lex = JsLexer.tokenize(source);
  parser.input = lex.tokens;
  parser.program();
  if (parser.errors.length) throw new Error(parser.errors[0].message);

  const toks = lex.tokens;
  const edits = []; // {pos, len?, str}

  // helper
  const isFunc = (i) =>
    toks[i].tokenType === FunctionKw && toks[i+1]?.tokenType === Identifier;

  for (let i=0;i<toks.length;i++) {
    if (!isFunc(i)) continue;
    const fnName = toks[i+1].image;
    // after opening brace inject let
    let j=i+2; while (toks[j].tokenType!==LCurly) j++;
    edits.push({ pos: toks[j].endOffset+1,
                 str: `\n  let ${fnName}Output;\n` });

    // walk until matching }
    let depth=1;
    for(let k=j+1; k<toks.length && depth>0; k++){
      if (toks[k].tokenType===LCurly) depth++;
      if (toks[k].tokenType===RCurly) depth--;
      if (depth===1 && toks[k].tokenType===ReturnKw){
        const exprTok=toks[k+1], semiTok=toks[k+2];
        const replacement=`${fnName}Output = ${exprTok.image}; `+
          `console.log(${fnName}Output); return ${fnName}Output;`;
        edits.push({ pos:toks[k].startOffset,
                     len:semiTok.endOffset-toks[k].startOffset+1,
                     str:replacement });
      }
    }
  }

  // apply edits back‑to‑front
  let out=source;
  edits.sort((a,b)=>b.pos-a.pos).forEach(e=>{
    out = (e.len==null)
      ? out.slice(0,e.pos)+e.str+out.slice(e.pos)
      : out.slice(0,e.pos)+e.str+out.slice(e.pos+e.len);
  });
  return out;
}

module.exports = { transformCode };
CHEVROTAIN


cat > "${SRC_DIR}/treeSitterTransformer.js" <<'TS'
// treeSitterTransformer.js
const Parser = require('tree-sitter');
const JavaScript = require('tree-sitter-javascript');

const parser = new Parser();
parser.setLanguage(JavaScript);

// ── Helper to find ancestor ─────────────────────────────────────────────
function ancestor(node, type){
  for(let n=node.parent; n; n=n.parent) if (n.type===type) return n;
  return null;
}

function transformCode(source){
  const tree = parser.parse(source);
  const edits=[];

  // 1. Inject let <fn>Output;
  const fnQuery = parser.getLanguage().query(`
    (function_declaration
      name: (identifier) @fname
      body: (statement_block) @body)
  `);
  fnQuery.matches(tree.rootNode).forEach(m=>{
    const fname = m.captures.find(c=>c.name==='fname').node.text;
    const body  = m.captures.find(c=>c.name==='body').node;
    edits.push({ pos: body.startIndex+1,
                 str:`\n  let ${fname}Output;\n` });
  });

  // 2. Rewrite returns
  const retQuery = parser.getLanguage().query(`
    (return_statement argument: (_) @arg)
  `);
  retQuery.matches(tree.rootNode).forEach(m=>{
    const arg = m.captures[0].node;
    const ret = arg.parent;
    const fn  = ancestor(ret,'function_declaration');
    if (!fn) return;
    const fname=fn.childForFieldName('name').text;
    const replacement =
      `${fname}Output = ${arg.text}; console.log(${fname}Output); return ${fname}Output;`;
    edits.push({ pos: ret.startIndex,
                 len: ret.endIndex-ret.startIndex,
                 str: replacement });
  });

  // apply edits back‑to‑front
  let out=source;
  edits.sort((a,b)=>b.pos-a.pos).forEach(e=>{
    out=(e.len==null)
      ? out.slice(0,e.pos)+e.str+out.slice(e.pos)
      : out.slice(0,e.pos)+e.str+out.slice(e.pos+e.len);
  });
  return out;
}

module.exports={ transformCode };
TS


echo "─── 4.  🧪  Writing Jest test‑suite ─────────────────────────────────────────"
cat > "${TEST_DIR}/transformers.test.js" <<'TEST'
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
TEST


echo "─── 5.  ▶️  Running tests ───────────────────────────────────────────────────"
npx jest --runInBand
echo "✅  All done!"