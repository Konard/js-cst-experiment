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
