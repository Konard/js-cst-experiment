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
