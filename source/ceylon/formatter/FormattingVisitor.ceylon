/********************************************************************************
 * Copyright (c) 2011-2017 Red Hat Inc. and/or its affiliates and others
 *
 * This program and the accompanying materials are made available under the 
 * terms of the Apache License, Version 2.0 which is available at
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * SPDX-License-Identifier: Apache-2.0 
 ********************************************************************************/
import org.eclipse.ceylon.compiler.typechecker.tree {
    Tree {
        ...
    },
    CustomTree {
        GuardedVariable
    },
    Node,
    VisitorAdaptor
}
import org.eclipse.ceylon.compiler.typechecker.parser {
    CeylonLexer {
        fish=\iFISH,
        pipe=\iPIPE,
        valueModifier=\iVALUE_MODIFIER
    }
}
import org.antlr.runtime {
    TokenStream {
        la=\iLA
    },
    Token
}
import ceylon.file {
    Writer
}
import ceylon.formatter.options {
    FormattingOptions
}
import ceylon.collection {
    MutableList,
    MutableMap,
    MutableSet,
    ArrayList,
    HashMap,
    HashSet
}

"A [[org.eclipse.ceylon.compiler.typechecker.tree::Visitor]] that writes a formatted version of the
 element (typically a [[org.eclipse.ceylon.compiler.typechecker.tree::Tree.CompilationUnit]]) to a
 [[Writer]]."
shared class FormattingVisitor(
    "The [[TokenStream]] from which the element was parsed;
     this is mainly needed to preserve comments, as they're not present in the AST."
    TokenStream? tokens,
    "The writer to which the subject is written."
    Writer writer,
    "The options for the formatter that control the format of the written code."
    FormattingOptions options,
    "The initial indentation level."
    Integer initialIndentation = 0)
        extends VisitorAdaptor()
        satisfies Destroyable {
    
    FormattingWriter fWriter = FormattingWriter(tokens, writer, options);
    if (initialIndentation != 0) {
        fWriter.openContext(initialIndentation);
    }
    
    """When visiting an annotation, some elements are formatted differently.
       For example:
       
           doc ("<-- space")
           print("<-- no space");"""
    variable Boolean visitingAnnotation = false;
    
    """Type specifiers in default type arguments may optionally be spaced,
       according to [[FormattingOptions.spaceAroundTypeParamListEqualsSign]];
       other type specifiers (class aliases etc.) are always spaced."""
    variable Boolean visitingDefaultTypeArgument = false;
    
    "Set of nodes that are a `switch`’s `else`,
     which are always put on their own line,
     not on the same line as the preceding `}` as for `if`’s `else`s."
    MutableSet<Node> switchElseNodes = HashSet<Node>();
    
    "Map from alias to actual name, for [#126](https://github.com/eclipse/ceylon.formatter/issues/126)."
    MutableMap<String,String> importMemberAliases = HashMap<String,String>();
    
    "Set of nodes that may be condensed into a single line under certain conditions."
    MutableSet<Node> singleLineNodes = HashSet<Node>();
    
    // initialize TokenStream
    if (exists tokens) { tokens.la(1); }
    
    String identifierText(Identifier identifier) {
        assert (exists text = identifier.text);
        if (text.startsWith("""\i""") || text.startsWith("""\I""")) {
            return text[2...];
        } else {
            return text;
        }
    }
    
    shared actual void handleException(Exception? e, Node that) {
        // set breakpoint here
        if (exists e) {
            if (options.failFast) {
                throw e;
            } else {
                e.printStackTrace();
            }
        }
    }
    
    shared actual void visitAbstractedType(AbstractedType that) {
        fWriter.writeToken {
            that.mainToken; // "abstracts"
            indentBefore = options.indentBeforeTypeInfo;
            lineBreaksAfter = noLineBreak;
            spaceBefore = true;
            spaceAfter = true;
        };
        that.type.visit(this);
    }
    
    shared actual void visitAlias(Alias that) {
        that.identifier.visit(this);
        fWriter.writeToken {
            that.mainToken; // "="
            lineBreaksBefore = noLineBreak;
            lineBreaksAfter = noLineBreak;
            spaceBefore = options.spaceAroundImportAliasEqualsSign;
            spaceAfter = options.spaceAroundImportAliasEqualsSign;
        };
    }
    
    shared actual void visitAliasLiteral(AliasLiteral that)
            => writeMetaLiteral(fWriter, this, that, "alias");
    
    shared actual void visitAnnotation(Annotation that) {
        "Annotations can’t be nested"
        assert (!visitingAnnotation);
        visitingAnnotation = true;
        that.visitChildren(this);
        visitingAnnotation = false;
        if (is {String*} inlineAnnotations = options.inlineAnnotations) {
            if (is BaseMemberExpression bme = that.primary,
                exists text = identifierText(bme.identifier) of String?, // simulated `let` inside condition :)
                (importMemberAliases[text] else text) in inlineAnnotations) {
                fWriter.requireAtMostLineBreaks(0);
            } else {
                fWriter.requireAtLeastLineBreaks(1);
            }
        } else {
            // no line breaks for any annotations
        }
    }
    
    shared actual void visitAnonymousAnnotation(AnonymousAnnotation that) {
        "Annotations can’t be nested"
        assert (!visitingAnnotation);
        visitingAnnotation = true;
        that.visitChildren(this);
        visitingAnnotation = false;
        fWriter.requireAtLeastLineBreaks(1);
    }
    
    shared actual void visitAnyClass(AnyClass that) {
        value context = fWriter.openContext();
        that.annotationList.visit(this);
        fWriter.writeToken {
            that.mainToken; // "class"
            lineBreaksAfter = noLineBreak;
            spaceBefore = true;
            spaceAfter = true;
        };
        that.identifier.visit(this);
        that.typeParameterList?.visit(this);
        that.parameterList?.visit(this);
        that.caseTypes?.visit(this);
        that.extendedType?.visit(this);
        that.satisfiedTypes?.visit(this);
        that.typeConstraintList?.visit(this);
        if (is ClassDefinition that) {
            that.classBody.visit(this);
            fWriter.closeContext(context);
        } else if (is ClassDeclaration that) {
            that.classSpecifier?.visit(this);
            writeSemicolon(fWriter, that.mainEndToken, context);
        }
    }
    
    shared actual void visitAnyInterface(AnyInterface that) {
        value context = fWriter.openContext();
        that.annotationList.visit(this);
        fWriter.writeToken {
            that.mainToken; // "interface" or "dynamic"
            lineBreaksAfter = noLineBreak;
            spaceBefore = true;
            spaceAfter = true;
        };
        that.identifier.visit(this);
        that.typeParameterList?.visit(this);
        that.caseTypes?.visit(this);
        that.satisfiedTypes?.visit(this);
        that.typeConstraintList?.visit(this);
        if (is InterfaceDefinition that) {
            that.interfaceBody.visit(this);
            fWriter.closeContext(context);
        } else if (is InterfaceDeclaration that) {
            that.typeSpecifier?.visit(this);
            writeSemicolon(fWriter, that.mainEndToken, context);
        }
    }
    
    shared actual void visitAnyMethod(AnyMethod that) {
        value context = fWriter.openContext();
        // override the default Walker's order
        that.annotationList.visit(this);
        that.type.visit(this);
        that.identifier.visit(this);
        that.typeParameterList?.visit(this);
        for (ParameterList list in that.parameterLists) {
            list.visit(this);
        }
        that.typeConstraintList?.visit(this);
        fWriter.closeContext(context);
    }
    
    shared actual void visitAssertion(Assertion that) {
        value context = fWriter.openContext();
        that.annotationList.visit(this);
        fWriter.writeToken {
            that.mainToken; // "assert"
            lineBreaksAfter = noLineBreak;
            spaceBefore = true; // TODO option
            spaceAfter = true;
        };
        that.conditionList.visit(this);
        writeSemicolon(fWriter, that.mainEndToken, context);
    }
    
    shared actual void visitAttributeArgument(AttributeArgument that) {
        value context = fWriter.openContext();
        that.type?.visit(this);
        that.identifier?.visit(this);
        if (exists expr = that.specifierExpression) {
            expr.visit(this);
            writeSemicolon(fWriter, that.mainEndToken, context);
        } else {
            that.block.visit(this);
        }
    }
    
    shared actual void visitAttributeDeclaration(AttributeDeclaration that) {
        value context = fWriter.openContext();
        visitAnyAttribute(that);
        if (exists expression = that.specifierOrInitializerExpression) {
            expression.visit(this);
        }
        if (exists endToken = that.mainEndToken) {
            writeSemicolon(fWriter, that.mainEndToken, context);
        } else {
            fWriter.closeContext(context);
        }
    }
    
    shared actual void visitAttributeGetterDefinition(AttributeGetterDefinition that) {
        visitAnyAttribute(that);
        that.block.visit(this);
    }
    
    shared actual void visitAttributeSetterDefinition(AttributeSetterDefinition that) {
        value context = fWriter.openContext();
        that.annotationList?.visit(this);
        writeModifier(fWriter, that.mainToken); // "assign"
        that.identifier.visit(this);
        if (exists expr = that.specifierExpression) {
            expr.visit(this);
            writeSemicolon(fWriter, that.mainEndToken, context);
        } else {
            // single-line assign foo { secretFoo = foo; } is allowed
            singleLineNodes.add(that.block);
            that.block.visit(this);
            singleLineNodes.remove(that.block);
            fWriter.closeContext(context);
        }
    }
    
    shared actual void visitBaseMemberExpression(BaseMemberExpression that) {
        that.identifier.visit(this);
        that.typeArguments?.visit(this);
    }
    
    shared actual void visitBaseType(BaseType that) {
        if (that.packageQualified) {
            // the C in `extends package.C()` is a BaseType with packageQualified = true
            fWriter.writeToken {
                that.mainToken; // "package"
                spaceBefore = true;
                spaceAfter = false;
                lineBreaksAfter = noLineBreak;
            };
            fWriter.writeToken {
                ".";
                spaceBefore = false;
                spaceAfter = false;
                lineBreaksBefore = noLineBreak;
                lineBreaksAfter = noLineBreak;
            };
        }
        that.typeVariance?.visit(this);
        that.identifier.visit(this);
        that.typeArgumentList?.visit(this);
    }
    
    shared actual void visitBaseTypeExpression(BaseTypeExpression that) {
        that.identifier.visit(this);
        that.typeArguments.visit(this);
    }
    
    shared actual void visitBinaryOperatorExpression(BinaryOperatorExpression that) {
        Term left = that.leftTerm;
        Term right = that.rightTerm;
        
        if (samePrecedence(left, that)) {
            // prevent stuff like 1+2 + 3, pretend it’s not a child
            left.visit(this);
        } else {
            // normal case – expressions like a*b + c*d
            visitBinaryOperatorExpressionChild(left);
        }
        
        writeBinaryOperator(fWriter, that.mainToken);
        
        if (samePrecedence(right, that)) {
            right.visit(this);
        } else {
            visitBinaryOperatorExpressionChild(right);
        }
    }
    
    "Visit an expression that is a child of another binary operator expression.
     
     If this is a binary operator expression itself, then the spaces around the operator
     might be omitted; see [[useSpacesAroundBinaryOp]] for details."
    see (`function useSpacesAroundBinaryOp`)
    void visitBinaryOperatorExpressionChild(Term that) {
        if (is BinaryOperatorExpression that) {
            Term left = that.leftTerm;
            Term right = that.rightTerm;
            visitBinaryOperatorExpressionChild(left);
            value useSpaces = useSpacesAroundBinaryOp(that, options.spaceOptionalAroundOperatorLevel);
            fWriter.writeToken {
                that.mainToken;
                lineBreaksBefore = useSpaces then 0..1 else noLineBreak;
                lineBreaksAfter = useSpaces then 0..1 else noLineBreak;
                spaceBefore = useSpaces;
                spaceAfter = useSpaces;
                indentBefore = 2;
                stackIndentBefore = never;
                indentAfter = 2;
                stackIndentAfter = never;
            };
            visitBinaryOperatorExpressionChild(right);
        } else if (is Expression that, !that.mainToken exists) {
            visitBinaryOperatorExpressionChild(that.term);
        } else {
            that.visit(this);
        }
    }
    
    shared actual void visitBody(Body that) {
        value statements = [*that.statements];
        // any block with more than one statement or an import list must be multi-line
        value multiline = !that in singleLineNodes || statements.longerThan(1) || that.importList exists;
        FormattingWriter.FormattingContext? context;
        if (exists token = that.mainToken) {
            context = fWriter.writeToken {
                token; // "{"
                indentAfter = 1;
                lineBreaksBefore = options.braceOnOwnLine then 1..1 else noLineBreak;
                lineBreaksAfter = tokens exists then 0..2 else 1..0;
                spaceBefore = 10;
                spaceAfter = statements nonempty;
            };
        } else {
            context = null;
        }
        that.importList?.visit(this);
        for (Statement statement in statements) {
            if (multiline) {
                fWriter.requireAtLeastLineBreaks(1);
            } else {
                /*
                 * Propagate single-line-ness and switch-else-ness for:
                 * 
                 * switch (something)
                 * case (whatever) {}
                 * else if (condition1) { oneStatement(); }
                 * else if (condition2) { singleLine(); }
                 * else { otherwise(); }
                 * 
                 * Those two `if`s have a pseudo-block with no brace tokens around them
                 * and need to know that they can be single-line and their elses are case elses (new line).
                 */
                if (that in singleLineNodes) {
                    singleLineNodes.add(statement);
                }
                if (that in switchElseNodes) {
                    switchElseNodes.add(statement);
                }
            }
            statement.visit(this);
            if (multiline) {
                fWriter.requireAtLeastLineBreaks(1);
            } else {
                singleLineNodes.remove(statement);
                switchElseNodes.remove(statement);
            }
        }
        if (exists token = that.mainEndToken) {
            fWriter.writeToken {
                token; // "}"
                lineBreaksBefore = 1..0;
                lineBreaksAfter = tokens exists then 0..3 else 2..0;
                spaceBefore = statements nonempty;
                spaceAfter = 5;
                context;
            };
        }
    }
    
    shared actual void visitBreak(Break that) {
        value context = fWriter.writeToken {
            that.mainToken; // "break"
            spaceAfter = false;
            lineBreaksAfter = noLineBreak;
        };
        assert (exists context);
        writeSemicolon(fWriter, that.mainEndToken, context);
    }
    
    shared actual void visitCaseClause(CaseClause that) {
        value lineBreaksBefore = that.block exists then 1..1 else 0..1; // allow inline switch/case/else expressions
        if (that.overlapping) {
            fWriter.writeToken {
                "else";
                spaceBefore = true;
                spaceAfter = true;
                lineBreaksBefore = lineBreaksBefore;
                lineBreaksAfter = noLineBreak;
            };
        }
        fWriter.writeToken {
            that.mainToken; // "case"
            spaceBefore = true;
            spaceAfter = options.spaceAfterControlStructureKeyword;
            lineBreaksBefore = that.overlapping then noLineBreak else lineBreaksBefore;
            lineBreaksAfter = noLineBreak;
        };
        value context = fWriter.writeToken {
            "(";
            /* not in the AST – there’s a TODO in Ceylon.g that “we really should not throw away this token”;
               for now, we produce it out of thin air :) */
            spaceAfter = false; // TODO option
            indentAfter = 1;
            lineBreaksAfter = noLineBreak;
        };
        that.caseItem?.visit(this); // nullsafe because the grammar allows case () { ... } – wtf?
        fWriter.writeToken {
            that.caseItem?.mainEndToken else ")";
            context;
            spaceBefore = false; // TODO option
            lineBreaksBefore = noLineBreak;
        };
        if (exists block = that.block) {
            // allow single-line case (something) { action(); }
            singleLineNodes.add(block);
            block.visit(this);
            singleLineNodes.remove(block);
        }
        if (exists expr = that.expression) {
            value exprContext = fWriter.openContext(1);
            expr.visit(this);
            fWriter.closeContext(exprContext);
        }
    }
    
    shared actual void visitCaseTypes(CaseTypes that) {
        value context = fWriter.writeToken {
            that.mainToken; // "of"
            spaceBefore = true;
            spaceAfter = true;
            indentBefore = options.indentBeforeTypeInfo;
            indentAfter = 1;
        };
        assert (exists context);
        // TODO replace casesList with ceylon-spec#947’s solution
        MutableList<StaticType|StaticMemberOrTypeExpression> casesList = ArrayList<StaticType|StaticMemberOrTypeExpression>();
        casesList.addAll { *that.types };
        casesList.addAll { *that.baseMemberExpressions };
        assert (nonempty cases = casesList.sort(byIncreasing(compose(Token.tokenIndex, Node.token))));
        cases.first.visit(this);
        for (item in cases.rest) {
            fWriter.writeToken {
                "|";
                lineBreaksBefore = noLineBreak;
                spaceBefore = options.spaceAroundSatisfiesOf;
                spaceAfter = options.spaceAroundSatisfiesOf;
            };
            item.visit(this);
        }
        fWriter.closeContext(context);
    }
    
    shared actual void visitCatchClause(CatchClause that) {
        fWriter.writeToken {
            that.mainToken; // "catch"
            spaceAfter = options.spaceAfterControlStructureKeyword;
            lineBreaksBefore = options.elseOnOwnLine then 1..1 else 0..0;
        };
        that.catchVariable.visit(this);
        that.block.visit(this);
    }
    
    shared actual void visitCatchVariable(CatchVariable that) {
        value context = fWriter.writeToken {
            that.mainToken; // "("
            spaceAfter = false;
            lineBreaksBefore = noLineBreak;
            indentAfter = 1;
        };
        that.variable?.visit(this); // nullsafe because the grammar allows catch ()
        fWriter.writeToken {
            that.mainEndToken; // ")"
            context;
            spaceBefore = false;
        };
    }
    
    shared actual void visitClassLiteral(ClassLiteral that)
            => writeMetaLiteral(fWriter, this, that, "class");
    
    shared actual void visitClassSpecifier(ClassSpecifier that) {
        fWriter.writeToken {
            that.mainToken; // "=" or "=>" – only "=>" is legal, but the grammar allows both
            spaceBefore = true;
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
            indentBefore = 2;
        };
        that.visitChildren(this);
    }
    
    shared actual void visitCompilationUnit(CompilationUnit compilationUnit) {
        compilationUnit.importList.visit(this);
        if (nonempty decs = concatenate(
                { *compilationUnit.moduleDescriptors },
                { *compilationUnit.packageDescriptors },
                { *compilationUnit.declarations }
            )) {
            if (!compilationUnit.importList.imports.empty) {
                fWriter.requireAtLeastLineBreaks(2);
            }
            decs.first.visit(this);
            for (dec in decs.rest) {
                fWriter.requireAtLeastLineBreaks(1);
                dec.visit(this);
            }
        }
    }
    
    shared actual void visitConditionList(ConditionList that) {
        value context = fWriter.writeToken {
            that.mainToken; // "("
            lineBreaksBefore = noLineBreak;
            indentAfter = 1;
            spaceAfter = false;
        };
        value conditions = [*that.conditions];
        "Empty condition list not allowed"
        assert (exists first = conditions.first);
        variable value innerContext = fWriter.openContext();
        first.visit(this);
        for (element in conditions.rest) {
            fWriter.writeToken {
                ",";
                lineBreaksBefore = noLineBreak;
                spaceBefore = false;
                spaceAfter = true;
                innerContext;
            };
            innerContext = fWriter.openContext();
            element.visit(this);
        }
        fWriter.writeToken {
            that.mainEndToken; // ")"
            lineBreaksBefore = noLineBreak;
            spaceBefore = false;
            spaceAfter = 0;
            context;
        };
    }
    
    shared actual void visitConstructor(Constructor that) {
        value context = fWriter.openContext();
        that.annotationList.visit(this);
        fWriter.writeToken {
            that.mainToken; // "new"
            spaceBefore = true;
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        that.identifier?.visit(this);
        that.parameterList?.visit(this);
        that.delegatedConstructor?.visit(this);
        that.block.visit(this);
        fWriter.closeContext(context);
    }
    
    shared actual void visitContinue(Continue that) {
        value context = fWriter.writeToken {
            that.mainToken; // "continue"
            spaceAfter = false;
            lineBreaksAfter = noLineBreak;
        };
        assert (exists context);
        writeSemicolon(fWriter, that.mainEndToken, context);
    }
    
    shared actual void visitDefaultedType(DefaultedType that) {
        that.type.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // "="
            lineBreaksBefore = noLineBreak;
            spaceBefore = false;
        };
    }
    
    shared actual void visitDefaultOp(DefaultOp that) {
        that.leftTerm.visit(this);
        fWriter.writeToken {
            that.mainToken; // "else"
            indentBefore = 2;
            spaceBefore = true;
            spaceAfter = true;
        };
        that.rightTerm.visit(this);
    }
    
    shared actual void visitDelegatedConstructor(DelegatedConstructor that) {
        fWriter.writeToken {
            that.mainToken; // "extends"
            indentBefore = options.indentBeforeTypeInfo;
            lineBreaksAfter = noLineBreak;
            spaceBefore = true;
            spaceAfter = true;
        };
        that.type.visit(this);
        that.invocationExpression.visit(this);
    }
    
    shared actual void visitDynamic(Dynamic that) {
        writeModifier(fWriter, that.mainToken); // "dynamic"
        if (exists namedArgumentList = that.namedArgumentList) {
            namedArgumentList.visit(this);
        } else {
            // empty dynamic array
            fWriter.writeToken {
                "[";
                lineBreaksBefore = noLineBreak;
                lineBreaksAfter = noLineBreak;
                spaceBefore = true;
                spaceAfter = false;
            };
            fWriter.writeToken {
                ",";
                lineBreaksBefore = noLineBreak;
                lineBreaksAfter = noLineBreak;
                spaceBefore = false;
                spaceAfter = false;
            };
            fWriter.writeToken {
                that.mainEndToken; // "]"
                lineBreaksBefore = noLineBreak;
                spaceBefore = false;
            };
        }
    }
    
    shared actual void visitDynamicClause(DynamicClause that) {
        writeModifier(fWriter, that.mainToken); // "dynamic"
        // allow single-line dynamic { eval("dark magic"); }
        singleLineNodes.add(that.block);
        that.block.visit(this);
        singleLineNodes.remove(that.block);
    }
    
    shared actual void visitDynamicModifier(DynamicModifier that)
            => writeModifier(fWriter, that.mainToken); // "dynamic"
    
    shared actual void visitElementRange(ElementRange that) {
        /* 
         An ElementRange can be anything that goes into an index expression (except a single element),
         that is, ...upper, lower..., lower..upper, and lower:length.
         The ..., .. and : tokens are all lost because the grammar for this part kinda sucks
         (TODO go bug someone about that),
         so we just have to infer them from which fields are null and which aren’t
         (for example, use : if there’s a length).
         */
        Expression? lower = that.lowerBound;
        Expression? upper = that.upperBound;
        Expression? length = that.length;
        
        variable Boolean wantsSpaces
                = !{ lower?.term, upper?.term, length?.term }.coalesced
                    .map(unwrapExpression)
                    .every((term) => term is ExpressionWithoutSpaces);
        
        if (exists lower) {
            if (exists length) {
                "Range can’t have an upper bound when it has a length"
                assert (is Null upper);
                visitBinaryOperatorExpressionChild(lower);
                fWriter.writeToken {
                    ":";
                    spaceBefore = wantsSpaces;
                    spaceAfter = wantsSpaces;
                    lineBreaksBefore = noLineBreak;
                    lineBreaksAfter = noLineBreak;
                };
                visitBinaryOperatorExpressionChild(length);
            } else if (exists upper) {
                visitBinaryOperatorExpressionChild(lower);
                fWriter.writeToken {
                    "..";
                    spaceBefore = wantsSpaces;
                    spaceAfter = wantsSpaces;
                    lineBreaksBefore = noLineBreak;
                    lineBreaksAfter = noLineBreak;
                };
                visitBinaryOperatorExpressionChild(upper);
            } else {
                visitBinaryOperatorExpressionChild(lower);
                fWriter.writeToken {
                    "...";
                    spaceBefore = wantsSpaces;
                    lineBreaksBefore = noLineBreak;
                };
            }
        } else {
            "Range can’t have a length without a lower bound"
            assert (is Null length);
            "Range can’t be unbounded"
            assert (exists upper);
            fWriter.writeToken {
                "...";
                spaceAfter = wantsSpaces;
                lineBreaksAfter = noLineBreak;
            };
            visitBinaryOperatorExpressionChild(upper);
        }
    }
    
    shared actual void visitElseClause(ElseClause that) {
        fWriter.writeToken {
            that.mainToken; // "else"
            value lineBreaksBefore {
                if (that.expression exists) {
                    return 0..1; // allow inline switch/case/else expressions
                } else if (options.elseOnOwnLine || that in switchElseNodes) {
                    return 1..1;
                } else {
                    return 0..0;
                }
            }
            spaceAfter = true;
        };
        if (exists block = that.block) {
            if (
                /*
                 * Allow
                 * 
                 * switch (foo)
                 * case (bar) {}
                 * else { baz(); }
                 */
                that in switchElseNodes ||
                        /*
                         * Allow
                         * 
                         * if (foo) {
                         *     // ...
                         * } else if (bar) {
                         *     // ...
                         * }
                         * 
                         * without forcing a line-break into the `else if`
                         * (the `else` has a pseudo-block with no brace tokens
                         * and the `if` as only child).
                         */
                !block.mainToken exists) {
                singleLineNodes.add(block);
            }
            if (that in switchElseNodes && !block.mainToken exists) {
                /*
                 * In
                 * 
                 * switch (foo)
                 * case (bar) {}
                 * else if (baz) {}
                 * else {}
                 * 
                 * the switch-else-ness must be propagated
                 * from the `else if`-`else` to the final `else`.
                 */
                switchElseNodes.add(block);
            }
            block.visit(this);
            singleLineNodes.remove(block);
            switchElseNodes.remove(block);
        }
        if (exists expr = that.expression) {
            value exprContext = fWriter.openContext(1);
            expr.visit(this);
            fWriter.closeContext(exprContext);
        }
    }
    
    shared actual void visitEntryOp(EntryOp that)
            => visitBinaryOperatorExpressionChild(that);
    
    shared actual void visitEntryType(EntryType that) {
        that.typeVariance?.visit(this);
        that.keyType.visit(this);
        fWriter.writeToken {
            "->";
            lineBreaksBefore = noLineBreak;
            lineBreaksAfter = noLineBreak;
            spaceBefore = false;
            spaceAfter = false;
        };
        that.valueType.visit(this);
    }
    
    shared actual void visitEnumerated(Enumerated that) {
        value context = fWriter.openContext();
        that.annotationList.visit(this);
        fWriter.writeToken {
            that.mainToken; // "new"
            spaceBefore = true;
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        that.identifier?.visit(this); // optional in the grammar
        that.delegatedConstructor?.visit(this);
        if (exists block = that.block) {
            that.block.visit(this);
            fWriter.closeContext(context);
        } else {
            // parser allows semicolon instead (with displayRecognitionError)
            writeSemicolon(fWriter, that.mainEndToken, context);
        }
    }
    
    shared actual void visitExists(Exists that) {
        value context = fWriter.openContext();
        that.term.visit(this);
        fWriter.writeToken {
            that.mainToken; // "exists"
            context;
            spaceBefore = true;
            lineBreaksBefore = noLineBreak;
        };
    }
    
    shared actual void visitExistsCondition(ExistsCondition that) {
        if (that.not) {
            fWriter.writeToken {
                that.mainToken; // "!"
                spaceAfter = false;
                lineBreaksAfter = noLineBreak;
            };
        }
        fWriter.writeToken {
            "exists";
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        that.visitChildren(this);
    }
    
    see (`function visitMatchList`)
    shared actual void visitExpressionList(ExpressionList that) {
        value expressions = [*that.expressions];
        assert (nonempty expressions);
        expressions.first.visit(this);
        for (expression in expressions.rest) {
            fWriter.writeToken {
                "|"; // not in the AST
                spaceBefore = true; // TODO options! same as in visitMatchList
                spaceAfter = true;
                lineBreaksBefore = noLineBreak;
            };
            expression.visit(this);
        }
    }
    
    shared actual void visitExtendedType(ExtendedType that) {
        fWriter.writeToken {
            that.mainToken; // "extends"
            indentBefore = options.indentBeforeTypeInfo;
            lineBreaksAfter = noLineBreak;
            spaceBefore = true;
            spaceAfter = true;
        };
        that.type.visit(this);
        that.invocationExpression?.visit(this);
    }
    
    shared actual void visitFinallyClause(FinallyClause that) {
        fWriter.writeToken {
            that.mainToken; // "finally"
            spaceAfter = true;
            lineBreaksBefore = options.elseOnOwnLine then 1..1 else 0..0;
        };
        that.block.visit(this);
    }
    
    "Visit an [[InvocationExpression]] which the parser synthesized
     when desugaring a fish expression (`lhs >|> rhs`)."
    shared void visitFishExpression(InvocationExpression that) {
        that.positionalArgumentList.positionalArguments.get(1).visit(this);
        writeBinaryOperator(fWriter, that.mainToken); // ">|>"
        that.positionalArgumentList.positionalArguments.get(0).visit(this);
    }
    
    shared actual void visitForClause(ForClause that) {
        fWriter.writeToken {
            that.mainToken; // "for"
            spaceAfter = options.spaceAfterControlStructureKeyword;
            lineBreaksAfter = noLineBreak;
        };
        that.visitChildren(this);
    }
    
    shared actual void visitForComprehensionClause(ForComprehensionClause that) {
        fWriter.writeToken {
            that.mainToken; // "for"
            spaceAfter = options.spaceAfterControlStructureKeyword;
            lineBreaksAfter = noLineBreak;
        };
        that.forIterator.visit(this);
        value context = fWriter.openContext(options.indentComprehensionClauses then 1 else 0);
        that.comprehensionClause.visit(this);
        fWriter.closeContext(context);
    }
    
    shared actual void visitFunctionArgument(FunctionArgument that) {
        that.type?.visit(this);
        that.typeParameterList?.visit(this);
        for (list in that.parameterLists) {
            visitParameterListAnonymous(list);
        }
        that.typeConstraintList?.visit(this);
        if (exists expr = that.expression) {
            fWriter.writeToken {
                "=>";
                spaceBefore = !that.parameterLists.empty then true else 0;
                spaceAfter = true;
                lineBreaksBefore = noLineBreak;
                indentAfter = 1;
            };
            expr.visit(this);
        } else {
            "Function argument must have either a specifier expression or a block"
            assert (exists block = that.block);
            block.visit(this);
        }
    }
    
    shared actual void visitFunctionLiteral(FunctionLiteral that)
            => writeMetaLiteral(fWriter, this, that, "function");
    
    shared actual void visitFunctionModifier(FunctionModifier that) {
        if (exists token = that.mainToken) {
            writeModifier(fWriter, token);
        }
    }
    
    shared actual void visitFunctionType(FunctionType that) {
        that.typeVariance?.visit(this);
        that.returnType.visit(this);
        value context = fWriter.writeToken {
            "(";
            spaceBefore = false;
            spaceAfter = false;
            lineBreaksBefore = noLineBreak;
            indentAfter = 1;
        };
        value argumentTypes = [*that.argumentTypes];
        if (nonempty argumentTypes) {
            argumentTypes.first.visit(this);
            for (argumentType in argumentTypes.rest) {
                fWriter.writeToken {
                    ",";
                    spaceBefore = false;
                    spaceAfter = true;
                    lineBreaksBefore = noLineBreak;
                };
                argumentType.visit(this);
            }
        }
        fWriter.writeToken {
            that.mainEndToken; // ")"
            context;
            spaceBefore = false;
        };
    }
    
    shared actual void visitGroupedType(Tree.GroupedType that) {
        that.typeVariance?.visit(this);
        value context = fWriter.writeToken {
            that.mainToken; // "<"
            lineBreaksAfter = noLineBreak;
            spaceAfter = false;
        };
        that.type.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // ">"
            context;
            lineBreaksBefore = noLineBreak;
            spaceBefore = false;
        };
    }
    
    shared actual void visitIdentifier(Identifier that) {
        fWriter.writeToken {
            that.text;
            tokenInStream = that.mainToken;
            lineBreaksBefore = 0..2;
        };
    }
    
    shared actual void visitIfClause(IfClause that) {
        fWriter.writeToken {
            that.mainToken; // "if"
            lineBreaksAfter = noLineBreak;
            spaceAfter = options.spaceAfterControlStructureKeyword;
        };
        // propagate single-line-ness to block, where the single-line decision is actually made
        if (that in singleLineNodes) {
            singleLineNodes.add(that.block);
        }
        that.visitChildren(this);
        singleLineNodes.remove(that.block);
    }
    
    shared actual void visitIfComprehensionClause(IfComprehensionClause that) {
        fWriter.writeToken {
            that.mainToken; // "if"
            lineBreaksAfter = noLineBreak;
            spaceAfter = options.spaceAfterControlStructureKeyword;
        };
        that.conditionList.visit(this);
        value context = fWriter.openContext(options.indentComprehensionClauses then 1 else 0);
        that.comprehensionClause.visit(this);
        fWriter.closeContext(context);
    }
    
    shared actual void visitIfExpression(IfExpression that) {
        fWriter.writeToken {
            that.mainToken; // "if"
            lineBreaksAfter = noLineBreak;
            spaceAfter = options.spaceAfterControlStructureKeyword;
        };
        that.ifClause.conditionList.visit(this);
        value thenContext = fWriter.writeToken {
            that.ifClause.mainToken; // "then"
            indentAfter = 1;
            spaceBefore = true;
            spaceAfter = true;
        };
        assert (exists thenContext);
        that.ifClause.expression.visit(this);
        fWriter.closeContext(thenContext);
        value elseContext = fWriter.writeToken {
            that.elseClause.mainToken; // "else"
            indentAfter = 1;
            spaceBefore = true;
            spaceAfter = true;
        };
        assert (exists elseContext);
        that.elseClause.expression.visit(this);
        fWriter.closeContext(elseContext);
    }
    
    shared actual void visitIfStatement(IfStatement that) {
        if (exists elseClause = that.elseClause) {
            // an if statement with an else clause is only eligible for being a single line
            // if it’s part of a switch else (else if),
            // in which case that information must be propagated to the inner else (else if ... else)
            if (that in switchElseNodes) {
                singleLineNodes.add(that);
                switchElseNodes.add(elseClause);
            } else {
                // otherwise, explicitly make this node not eligible for being a single line
                singleLineNodes.remove(that);
            }
        } else {
            // an if statement without an else clause is always eligible for being in a single line
            // (but usually won’t make the cut, when visitBody discovers it has more than one statement)
            singleLineNodes.add(that);
        }
        if (that in singleLineNodes) {
            // and now, actually propagate the decision made in either of the blocks above to the child clause
            singleLineNodes.add(that.ifClause);
        }
        that.visitChildren(this);
        singleLineNodes.remove(that.ifClause);
        if (exists elseClause = that.elseClause) {
            switchElseNodes.remove(elseClause);
        }
    }
    
    shared actual void visitImport(Import that) {
        fWriter.writeToken {
            that.mainToken; // "import"
            lineBreaksBefore = 2..0;
            lineBreaksAfter = noLineBreak;
            spaceBefore = false;
            spaceAfter = true;
        };
        that.visitChildren(this);
        fWriter.requireAtLeastLineBreaks(1);
    }
    
    shared actual void visitImportMember(ImportMember that) {
        if (exists al = that.\ialias) {
            importMemberAliases[identifierText(al.identifier)] = identifierText(that.identifier);
        }
        that.visitChildren(this);
    }
    
    shared actual void visitImportMemberOrTypeList(ImportMemberOrTypeList that) {
        value context = fWriter.writeToken {
            that.mainToken; // "{"
            lineBreaksBefore = noLineBreak;
            lineBreaksAfter = options.lineBreaksBetweenImportElements;
            indentAfter = 1;
            spaceBefore = true;
            spaceAfter = true;
        };
        if (exists membersOrTypes = that.importMemberOrTypes,
            nonempty elements = [*membersOrTypes]) {
            variable value innerContext = fWriter.openContext();
            void writeCommaAndVisitNext(Node node) {
                fWriter.writeToken {
                    ",";
                    lineBreaksBefore = noLineBreak;
                    lineBreaksAfter = options.lineBreaksBetweenImportElements;
                    spaceBefore = false;
                    spaceAfter = true;
                    innerContext;
                };
                innerContext = fWriter.openContext();
                node.visit(this);
            }
            elements.first.visit(this);
            for (value element in elements.rest) {
                writeCommaAndVisitNext(element);
            }
            if (exists wildcard = that.importWildcard) {
                writeCommaAndVisitNext(wildcard);
            }
            fWriter.closeContext(innerContext);
        } else {
            assert (exists wildcard = that.importWildcard);
            wildcard.visit(this);
        }
        fWriter.writeToken {
            that.mainEndToken; // "}"
            lineBreaksBefore = options.lineBreaksBetweenImportElements;
            lineBreaksAfter = 0..3;
            spaceBefore = true;
            spaceAfter = 1000;
            context;
        };
    }
    
    shared actual void visitImportModule(ImportModule that) {
        value context = fWriter.openContext();
        that.annotationList.visit(this);
        fWriter.writeToken {
            that.mainToken; // "import"
            spaceBefore = true;
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        if (exists namespace = that.namespace) {
            namespace.visit(this);
            fWriter.writeToken {
                ":";
                spaceBefore = false;
                spaceAfter = false;
                lineBreaksBefore = noLineBreak;
                lineBreaksAfter = noLineBreak;
            };
        }
        that.importPath?.visit(this); // nullsafe because might be quoted…
        that.quotedLiteral?.visit(this); // …like this
        if (exists artifact = that.artifact) {
            fWriter.writeToken {
                ":";
                spaceBefore = false;
                spaceAfter = false;
                lineBreaksBefore = noLineBreak;
                lineBreaksAfter = noLineBreak;
            };
            artifact.visit(this);
            if (exists classifier = that.classifier) {
                fWriter.writeToken {
                    ":";
                    spaceBefore = false;
                    spaceAfter = false;
                    lineBreaksBefore = noLineBreak;
                    lineBreaksAfter = noLineBreak;
                };
                classifier.visit(this);
            }
        }
        that.version?.visit(this); // nullsafe because it might be a constant…
        that.constantVersion?.visit(this); // …like this (or totally absent, it’s optional in the grammar)
        writeSemicolon(fWriter, that.mainEndToken, context);
    }
    
    shared actual void visitImportModuleList(ImportModuleList that) {
        value context = fWriter.writeToken {
            that.mainToken; // "{"
            spaceBefore = true;
            spaceAfter = true;
            lineBreaksBefore = options.braceOnOwnLine then 1..1 else noLineBreak;
            lineBreaksAfter = 1..2;
            indentAfter = 1;
        };
        
        // constants and importModules can be interleaved, but are stored in two lists,
        // so we have to mix them and sort by token index (cf. casesList in visitCaseTypes)
        MutableList<AnyAttribute|ImportModule> contentsList = ArrayList<AnyAttribute|ImportModule>();
        contentsList.addAll { *that.constants };
        contentsList.addAll { *that.importModules };
        value contents = contentsList.sort(byIncreasing(compose(Token.tokenIndex, Node.token)));
        for (content in contents) {
            content.visit(this);
        }
        
        fWriter.writeToken {
            that.mainEndToken; // "}"
            context;
            lineBreaksBefore = 1..1;
        };
    }
    
    shared actual void visitImportPath(ImportPath that) {
        value identifiers = [*that.identifiers];
        "Import can’t have empty import path"
        assert (nonempty identifiers);
        identifiers.first.visit(this);
        for (value identifier in identifiers.rest) {
            fWriter.writeToken {
                ".";
                indentBefore = 1;
                lineBreaksAfter = noLineBreak;
                spaceBefore = false;
                spaceAfter = false;
            };
            identifier.visit(this);
        }
    }
    
    shared actual void visitImportWildcard(ImportWildcard that) {
        fWriter.writeToken {
            that.mainToken; // "..."
            spaceBefore = true;
            spaceAfter = true;
        };
    }
    
    shared actual void visitIndexExpression(IndexExpression that) {
        that.primary.visit(this);
        value context = fWriter.writeToken {
            that.mainToken; // "["
            spaceBefore = false;
            spaceAfter = false;
            lineBreaksBefore = noLineBreak;
            lineBreaksAfter = noLineBreak;
        };
        that.elementOrRange.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // "]"
            context;
            spaceBefore = false;
            lineBreaksBefore = noLineBreak;
        };
    }
    
    shared actual void visitInterfaceLiteral(InterfaceLiteral that)
            => writeMetaLiteral(fWriter, this, that, "interface");
    
    shared actual void visitIntersectionType(IntersectionType that) {
        that.typeVariance?.visit(this);
        value types = [*that.staticTypes];
        "Empty union type not allowed"
        assert (nonempty types);
        types.first.visit(this);
        for (type in types.rest) {
            fWriter.writeToken {
                "&";
                lineBreaksBefore = noLineBreak;
                lineBreaksAfter = noLineBreak;
                spaceBefore = false;
                spaceAfter = false;
            };
            type.visit(this);
        }
    }
    
    shared actual void visitInvocationExpression(InvocationExpression that) {
        if (exists mainToken = that.mainToken,
            mainToken.type == pipe) {
            visitPipeExpression(that);
            return;
        }
        if (exists mainToken = that.mainToken,
            mainToken.type == fish) {
            visitFishExpression(that);
            return;
        }
        
        that.primary.visit(this);
        if (exists PositionalArgumentList list = that.positionalArgumentList) {
            list.visit(this);
        } else if (exists NamedArgumentList list = that.namedArgumentList) {
            list.visit(this);
        }
    }
    
    shared actual void visitIsCase(IsCase that) {
        fWriter.writeToken {
            that.mainToken; // "is"
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        that.type.visit(this);
        // Note: Do not visitChildren! compiler adds Variable to node (the variable whose type is tested), but that’s not in the code.
    }
    
    shared actual void visitIsCondition(IsCondition that) {
        if (that.not) {
            fWriter.writeToken {
                that.mainToken; // "!"
                spaceAfter = false;
                lineBreaksAfter = noLineBreak;
            };
        }
        fWriter.writeToken {
            "is";
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        that.type.visit(this);
        that.variable.visit(this);
    }
    
    shared actual void visitIterableType(IterableType that) {
        that.typeVariance?.visit(this);
        value context = fWriter.writeToken {
            that.mainToken; // "{"
            lineBreaksAfter = noLineBreak;
            spaceAfter = false;
        };
        that.elementType.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // "}"
            lineBreaksBefore = noLineBreak;
            spaceBefore = false;
            context = context;
        };
    }
    
    shared actual void visitKeyValuePattern(KeyValuePattern that) {
        that.key.visit(this);
        Boolean spacesAround = { that.key, that.\ivalue }.any((pattern) {
                if (is VariablePattern pattern) {
                    if (is ValueModifier type = pattern.variable.type) {
                        return type.mainToken exists; // fake value modifiers have no token
                    } else {
                        return true;
                    }
                } else {
                    return false;
                }
            });
        fWriter.writeToken {
            "->"; // token is nowhere in the AST
            spaceBefore = spacesAround;
            spaceAfter = spacesAround;
            lineBreaksBefore = spacesAround then 0..1 else noLineBreak;
            lineBreaksAfter = spacesAround then 0..1 else noLineBreak;
        };
        that.\ivalue.visit(this);
    }
    
    shared actual void visitLetClause(LetClause that) {
        fWriter.writeToken {
            that.mainToken; // "let"
            lineBreaksAfter = noLineBreak;
            spaceAfter = options.spaceAfterControlStructureKeyword;
        };
        value parenContext = fWriter.writeToken {
            "(";
            lineBreaksBefore = noLineBreak;
            indentAfter = 1;
            spaceAfter = false;
        };
        value variables = [*that.variables];
        "Empty variable list not allowed"
        assert (exists first = variables.first);
        variable value innerContext = fWriter.openContext();
        first.visit(this);
        for (variable in variables.rest) {
            fWriter.writeToken {
                ",";
                lineBreaksBefore = noLineBreak;
                spaceBefore = false;
                spaceAfter = true;
                innerContext;
            };
            innerContext = fWriter.openContext();
            variable.visit(this);
        }
        fWriter.writeToken {
            ")"; // deleted from the AST
            lineBreaksBefore = noLineBreak;
            spaceBefore = false;
            spaceAfter = 0;
            parenContext;
        };
        value context = fWriter.openContext(1);
        that.expression.visit(this);
        fWriter.closeContext(context);
    }
    
    shared actual void visitLetStatement(LetStatement that) {
        if (that.mainToken.type == valueModifier) {
            // old syntax: value [x] = [1];
            assert (exists context = writeModifier(fWriter, that.mainToken)); // "value"
            that.visitChildren(this);
            writeSemicolon(fWriter, that.mainEndToken, context);
        } else {
            // new syntax: let ([x] = [1]);
            assert (exists context = writeModifier(fWriter, that.mainToken)); // "let"
            value parenContext = fWriter.writeToken {
                "(";
                spaceAfter = false;
                indentAfter = 1;
                lineBreaksBefore = noLineBreak;
            };
            assert (nonempty variables = [*that.variables]);
            variables.first.visit(this);
            for (variable in variables.rest) {
                fWriter.writeToken {
                    ",";
                    lineBreaksBefore = noLineBreak;
                    spaceBefore = false;
                    spaceAfter = true;
                };
                variable.visit(this);
            }
            fWriter.writeToken {
                ")";
                spaceBefore = false;
                lineBreaksBefore = 0..1;
                context = parenContext;
            };
            writeSemicolon(fWriter, that.mainEndToken, context);
        }
    }
    
    shared actual void visitLiteral(Literal that) {
        fWriter.writeToken {
            that.mainToken;
            spaceBefore = 1;
            spaceAfter = 1;
            lineBreaksBefore = visitingAnnotation then 0..3 else 0..1;
        };
    }
    
    shared actual void visitMatchCase(MatchCase that)
            => that.expressionList.visit(this);
    
    shared actual void visitMatchList(MatchList that) {
        MutableList<Type|Expression> matchesList = ArrayList<Type|Expression>();
        matchesList.addAll { *that.types };
        matchesList.addAll { *that.expressions };
        assert (nonempty matches = matchesList.sort(byIncreasing(compose(Token.tokenIndex, Node.token))));
        matches.first.visit(this);
        for (item in matches.rest) {
            fWriter.writeToken {
                "|"; // not in the AST
                spaceBefore = true; // TODO options! same as in visitExpressionList
                spaceAfter = true;
                lineBreaksBefore = noLineBreak;
            };
            item.visit(this);
        }
    }
    
    shared actual void visitMemberOp(MemberOp that)
            => writeSomeMemberOp(fWriter, that.mainToken);
    
    shared actual void visitMetaLiteral(MetaLiteral that)
            => writeMetaLiteral(fWriter, this, that, null);
    
    shared actual void visitMethodArgument(MethodArgument that) {
        value context = fWriter.openContext();
        that.type.visit(this);
        that.identifier.visit(this);
        that.typeParameterList?.visit(this);
        for (paramList in that.parameterLists) {
            paramList.visit(this);
        }
        if (exists block = that.block) {
            block.visit(this);
        } else {
            that.specifierExpression?.visit(this);
            writeSemicolon(fWriter, that.mainEndToken, context);
        }
    }
    
    shared actual void visitMethodDeclaration(MethodDeclaration that) {
        value context = fWriter.openContext();
        visitAnyMethod(that);
        that.specifierExpression?.visit(this);
        if (exists semicolon = that.mainEndToken) {
            writeSemicolon(fWriter, semicolon, context);
        } else {
            fWriter.closeContext(context);
        }
    }
    
    shared actual void visitMethodDefinition(MethodDefinition that) {
        value context = fWriter.openContext();
        visitAnyMethod(that);
        fWriter.closeContext(context);
        that.block.visit(this);
    }
    
    shared actual void visitModuleDescriptor(ModuleDescriptor that) {
        that.annotationList.visit(this);
        fWriter.writeToken {
            that.mainToken; // "module"
            spaceBefore = true;
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        that.importPath.visit(this);
        if (exists ins = that.namespace) {
            ins.visit(this);
            fWriter.writeToken {
                ":";
                spaceBefore = false;
                spaceAfter = false;
                lineBreaksBefore = noLineBreak;
                lineBreaksAfter = noLineBreak;
            };
            that.groupQuotedLiteral?.visit(this);
            that.groupImportPath?.visit(this);
            if (exists artifact = that.artifact) {
                fWriter.writeToken {
                    ":";
                    spaceBefore = false;
                    spaceAfter = false;
                    lineBreaksBefore = noLineBreak;
                    lineBreaksAfter = noLineBreak;
                };
                artifact.visit(this);
                if (exists classifier = that.classifier) {
                    fWriter.writeToken {
                        ":";
                        spaceBefore = false;
                        spaceAfter = false;
                        lineBreaksBefore = noLineBreak;
                        lineBreaksAfter = noLineBreak;
                    };
                    classifier.visit(this);
                }
            }
        }
        that.version.visit(this);
        that.importModuleList.visit(this);
    }
    
    shared actual void visitModuleLiteral(ModuleLiteral that)
            => writeMetaLiteral(fWriter, this, that, "module");
    
    shared actual void visitNamedArgumentList(NamedArgumentList that) {
        value context = fWriter.writeToken {
            that.mainToken; // "{" or "[" (dynamic value)
            spaceAfter = true;
            lineBreaksAfter = 1..0;
            indentAfter = 1;
            indentBefore = 1; // see #38
        };
        for (arg in that.namedArguments) {
            arg.visit(this);
        }
        that.sequencedArgument?.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // "}" or "]" (dynamic value)
            context;
            spaceBefore = true;
            lineBreaksBefore = 1..0;
        };
    }
    
    shared actual void visitNegativeOp(NegativeOp that) {
        fWriter.writeToken {
            that.mainToken; // "-"
            spaceAfter = !that.term is Primary; // #83
            lineBreaksAfter = noLineBreak;
        };
        that.term.visit(this);
    }
    
    shared actual void visitNewLiteral(NewLiteral that)
            => writeMetaLiteral(fWriter, this, that, "new");
    
    shared actual void visitNonempty(Nonempty that) {
        value context = fWriter.openContext();
        that.term.visit(this);
        fWriter.writeToken {
            that.mainToken; // "nonempty"
            context;
            spaceBefore = true;
            lineBreaksBefore = noLineBreak;
        };
    }
    
    shared actual void visitNonemptyCondition(NonemptyCondition that) {
        if (that.not) {
            fWriter.writeToken {
                that.mainToken; // "!"
                spaceAfter = false;
                lineBreaksAfter = noLineBreak;
            };
        }
        fWriter.writeToken {
            "nonempty";
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        that.visitChildren(this);
    }
    
    shared actual void visitNotOp(NotOp that) {
        fWriter.writeToken {
            that.mainToken; // "!"
            spaceAfter = false;
            lineBreaksAfter = noLineBreak;
        };
        that.term.visit(this);
    }
    
    shared actual void visitObjectArgument(ObjectArgument that) {
        value context = fWriter.writeToken {
            that.mainToken; // "object"
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        assert (exists context);
        that.identifier.visit(this);
        that.extendedType?.visit(this);
        that.satisfiedTypes?.visit(this);
        if (exists body = that.classBody) {
            body.visit(this);
            fWriter.closeContext(context);
        } else {
            /*
             If I understand the grammar correctly, it’s possible to replace the body with a semicolon.
             In that case, the parser will add a recognition error, but then continue parsing.
             I guess that qualifies as syntactically valid-ish code, so we support it here.
             */
            writeSemicolon(fWriter, that.mainEndToken, context);
        }
    }
    
    shared actual void visitObjectDefinition(ObjectDefinition that) {
        that.annotationList?.visit(this);
        fWriter.writeToken {
            that.mainToken; // "object"
            spaceAfter = true;
        };
        that.identifier.visit(this);
        that.extendedType?.visit(this);
        that.satisfiedTypes?.visit(this);
        that.classBody.visit(this);
    }
    
    shared actual void visitObjectExpression(ObjectExpression that) {
        fWriter.writeToken {
            that.mainToken; // "object"
            spaceAfter = true;
        };
        that.extendedType?.visit(this);
        that.satisfiedTypes?.visit(this);
        that.classBody.visit(this);
    }
    
    shared actual void visitOptionalType(OptionalType that) {
        that.typeVariance?.visit(this);
        that.definiteType.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // "?"
            lineBreaksBefore = noLineBreak;
            spaceBefore = false;
        };
    }
    
    shared actual void visitOuter(Outer that) {
        fWriter.writeToken {
            that.mainToken; // "outer"
        };
    }
    
    shared actual void visitPackage(Package that) {
        fWriter.writeToken {
            that.mainToken; // "package"
        };
    }
    
    shared actual void visitPackageDescriptor(PackageDescriptor that) {
        value context = fWriter.openContext();
        that.annotationList.visit(this);
        fWriter.writeToken {
            that.mainToken; // "import"
            spaceBefore = true;
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        that.importPath.visit(this);
        writeSemicolon(fWriter, that.mainEndToken, context);
    }
    
    shared actual void visitPackageLiteral(PackageLiteral that)
            => writeMetaLiteral(fWriter, this, that, "package");
    
    shared actual void visitParameterList(ParameterList that)
            => doVisitParameterList(that, true);
    
    """Special version of [[visitParameterList]] that does not give the parameter list’s opening "(" a preIndent,
       for use by anonymous functions."""
    see (`function visitFunctionArgument`)
    void visitParameterListAnonymous(ParameterList that)
            => doVisitParameterList(that, false);
    
    void doVisitParameterList(ParameterList that, Boolean haveIndentBefore) {
        variable Boolean multiLine = false;
        object multiLineVisitor extends VisitorAdaptor() {
            shared actual void visitAnnotation(Annotation annotation) {
                if (is {String*} inlineAnnotations = options.inlineAnnotations) {
                    if (is BaseMemberExpression bme = annotation.primary,
                        exists text = bme.identifier.text,
                        text in inlineAnnotations) {
                        // not multiLine
                    } else {
                        multiLine = true;
                    }
                } else {
                    // not multiLine
                }
            }
            shared actual void visitAnonymousAnnotation(AnonymousAnnotation? anonymousAnnotation) {
                multiLine = true;
            }
        }
        that.visitChildren(multiLineVisitor);
        
        value context = fWriter.writeToken {
            that.mainToken; // "("
            indentBefore = haveIndentBefore then 2 else 0;
            indentAfter = 1;
            lineBreaksAfter = multiLine then 1..1 else 0..1;
            spaceBefore = options.spaceBeforeParamListOpeningParen;
            spaceAfter = options.spaceAfterParamListOpeningParen;
        };
        
        variable FormattingWriter.FormattingContext? previousContext = null;
        for (Parameter parameter in that.parameters) {
            if (exists c = previousContext) {
                fWriter.writeToken {
                    ",";
                    lineBreaksBefore = noLineBreak;
                    lineBreaksAfter = multiLine then 1..1 else 0..1;
                    spaceBefore = false;
                    spaceAfter = true;
                    context = c;
                };
            }
            previousContext = fWriter.openContext();
            parameter.visit(this);
        }
        fWriter.writeToken {
            that.mainEndToken; // ")"
            lineBreaksBefore = noLineBreak;
            spaceBefore = options.spaceBeforeParamListClosingParen;
            spaceAfter = options.spaceAfterParamListClosingParen then 10 else false;
            context = context;
        };
    }
    
    shared actual void visitParExpression(ParExpression that) {
        value context = fWriter.writeToken {
            that.mainToken; // "("
            indentAfter = 1;
            spaceAfter = false;
        };
        that.term.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // ")"
            context;
            spaceBefore = false;
        };
    }
    
    shared actual void visitPatternIterator(PatternIterator that) {
        value context = fWriter.writeToken {
            that.mainToken; // "("
            spaceAfter = options.spaceAfterValueIteratorOpeningParenthesis;
            lineBreaksAfter = noLineBreak;
        };
        that.pattern.visit(this);
        that.specifierExpression.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // ")"
            context;
            spaceBefore = options.spaceBeforeValueIteratorClosingParenthesis;
            lineBreaksBefore = noLineBreak;
        };
    }
    
    "Visit an [[InvocationExpression]] which the parser synthesized
     when desugaring a pipe expression (`lhs |> rhs`)."
    shared void visitPipeExpression(InvocationExpression that) {
        that.positionalArgumentList.positionalArguments.get(0).visit(this);
        writeBinaryOperator(fWriter, that.mainToken); // "|>"
        that.primary.visit(this);
    }
    
    shared actual void visitPositionalArgumentList(PositionalArgumentList that) {
        Token? openingParen = that.mainToken;
        Token? closingParen = that.mainEndToken;
        if (exists openingParen, exists closingParen) {
            value context = fWriter.writeToken {
                that.mainToken; // "("
                lineBreaksBefore = noLineBreak;
                indentAfter = 1;
                spaceBefore = visitingAnnotation
                        then options.spaceBeforeAnnotationPositionalArgumentList
                        else options.spaceBeforeMethodOrClassPositionalArgumentList;
                spaceAfter = false;
            };
            variable FormattingWriter.FormattingContext? previousContext = null;
            for (PositionalArgument argument in that.positionalArguments) {
                if (exists c = previousContext) {
                    fWriter.writeToken {
                        ",";
                        c;
                        lineBreaksBefore = noLineBreak;
                        spaceBefore = false;
                        spaceAfter = true;
                    };
                }
                previousContext = fWriter.openContext();
                argument.visit(this);
            }
            fWriter.writeToken {
                that.mainEndToken; // ")"
                spaceBefore = false;
                spaceAfter = 5;
                context;
            };
        } else {
            // annotations with no arguments
            // do nothing
        }
    }
    
    shared actual void visitPositiveOp(PositiveOp that) {
        fWriter.writeToken {
            that.mainToken; // "+"
            spaceAfter = !that.term is Primary; // #83
            lineBreaksAfter = noLineBreak;
        };
        that.term.visit(this);
    }
    
    shared actual void visitPostfixOperatorExpression(PostfixOperatorExpression that) {
        that.term.visit(this);
        fWriter.writeToken {
            that.mainToken; // "++" or "--"
            spaceBefore = false;
            lineBreaksBefore = noLineBreak;
        };
    }
    
    shared actual void visitPrefixOperatorExpression(PrefixOperatorExpression that) {
        fWriter.writeToken {
            that.mainToken; // "++" or "--"
            spaceAfter = false;
            lineBreaksAfter = noLineBreak;
        };
        that.term.visit(this);
    }
    
    shared actual void visitQualifiedMemberOrTypeExpression(QualifiedMemberOrTypeExpression that) {
        that.primary.visit(this);
        that.memberOperator.visit(this);
        that.identifier.visit(this);
        that.typeArguments.visit(this);
    }
    
    shared actual void visitQualifiedType(QualifiedType that) {
        that.typeVariance?.visit(this);
        that.outerType.visit(this);
        fWriter.writeToken {
            that.mainToken else "."; // the 'else "."' seems to be necessary for 'super.Klass' types
            spaceBefore = false;
            spaceAfter = false;
            lineBreaksBefore = noLineBreak;
            lineBreaksAfter = noLineBreak;
        };
        that.identifier.visit(this);
    }
    
    shared actual void visitRangeOp(RangeOp that)
            => visitBinaryOperatorExpressionChild(that);
    
    shared actual void visitResourceList(ResourceList that) {
        value context = fWriter.writeToken {
            that.mainToken; // "("
            indentAfter = 1;
            spaceAfter = false;
        };
        value resources = [*that.resources];
        if (nonempty resources) { // grammar allows empty resource list
            variable Resource lastResource = resources.first;
            lastResource.visit(this);
            for (resource in resources.rest) {
                fWriter.writeToken {
                    ","; /* the grammar sets the COMMA token as the end token of the entire resource list,
                            where it is overwritten by later commas and finally the closing parenthesis */
                    spaceBefore = false;
                    spaceAfter = true;
                    lineBreaksBefore = noLineBreak;
                };
                resource.visit(this);
                lastResource = resource;
            }
        }
        fWriter.writeToken {
            that.mainEndToken; // ")"
            context;
            spaceBefore = false;
        };
    }
    
    shared actual void visitReturn(Return that) {
        value context = fWriter.writeToken {
            that.mainToken; // "return"
            indentAfter = 1;
            stackIndentAfter = ifApplied;
            spaceAfter = that.expression exists;
            lineBreaksAfter = that.expression exists then 0..1 else 0..0;
        };
        assert (exists context);
        that.expression?.visit(this);
        writeSemicolon(fWriter, that.mainEndToken, context);
    }
    
    shared actual void visitSafeMemberOp(SafeMemberOp that)
            => writeSomeMemberOp(fWriter, that.mainToken);
    
    shared actual void visitSatisfiedTypes(SatisfiedTypes that) {
        value context = fWriter.writeToken {
            that.mainToken; // "satisfies"
            indentBefore = options.indentBeforeTypeInfo;
            lineBreaksAfter = noLineBreak;
            spaceBefore = true;
            spaceAfter = true;
        };
        assert (exists context);
        value typesContext = fWriter.openContext(2 * options.indentBeforeTypeInfo);
        value types = [*that.types];
        "Must satisfy at least one type"
        assert (nonempty types);
        types.first.visit(this);
        for (type in types.rest) {
            fWriter.writeToken {
                "&";
                lineBreaksBefore = noLineBreak;
                spaceBefore = options.spaceAroundSatisfiesOf;
                spaceAfter = options.spaceAroundSatisfiesOf;
            };
            type.visit(this);
        }
        fWriter.closeContext(typesContext);
        fWriter.closeContext(context);
    }
    
    shared actual void visitSatisfiesCase(SatisfiesCase that) {
        fWriter.writeToken {
            that.mainToken; // "satisfies"
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        that.visitChildren(this);
    }
    
    shared actual void visitSegmentOp(SegmentOp that)
            => visitBinaryOperatorExpressionChild(that);
    
    shared actual void visitSelfExpression(SelfExpression that) {
        fWriter.writeToken {
            that.mainToken; // "this" or "super"
        };
    }
    
    shared actual void visitSequencedArgument(SequencedArgument that) {
        value elements = [*that.positionalArguments];
        "Empty sequenced argument not allowed"
        assert (nonempty elements);
        elements.first.visit(this);
        for (element in elements.rest) {
            fWriter.writeToken {
                ",";
                spaceBefore = false;
                spaceAfter = true;
                lineBreaksBefore = noLineBreak;
            };
            element.visit(this);
        }
    }
    
    shared actual void visitSequencedType(SequencedType that) {
        // String* is a SequencedType
        // the rest in the destructure pattern [first, *rest] or [first, String *rest] also has a SequencedType
        // the * is the end token in the former case, and the start token in the latter case.
        that.type.visit(this);
        fWriter.writeToken {
            that.mainEndToken else that.mainToken; // "*" or "+";
            lineBreaksBefore = noLineBreak;
            lineBreaksAfter = noLineBreak;
            spaceBefore = !that.mainEndToken exists;
            spaceAfter = that.mainEndToken exists then 10 else false;
        };
    }
    
    shared actual void visitSequenceEnumeration(SequenceEnumeration that) {
        /*
         * In correct Ceylon, a SequenceEnumeration (iterable expression)
         * can only contain a SequencedArgument:
         * 
         *     { a, b, c }
         *       /*****/   // a single sequenced argument
         * 
         * However, to better handle the somewhat common mistake
         * 
         *     String f() => { a(); b(); return "c"; }
         * 
         * (erroneous `=>` before function block),
         * the parser also supports statements in there,
         * and so does ceylon.formatter.
         */
        value empty = !that.sequencedArgument exists && that.statements.empty;
        value context = fWriter.writeToken {
            that.mainToken; // "{"
            spaceAfter = !empty
                    then options.spaceAfterSequenceEnumerationOpeningBrace
                    else false;
            indentAfter = 1;
        };
        that.statements*.visit(this); // usually empty
        that.sequencedArgument?.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // "}"
            context;
            spaceBefore = !empty
                    then options.spaceBeforeSequenceEnumerationClosingBrace
                    else false;
        };
    }
    
    shared actual void visitSequenceType(SequenceType that) {
        // String[] is a SequenceType
        that.typeVariance?.visit(this);
        that.elementType.visit(this);
        fWriter.writeToken {
            "["; // doesn’t seem like that token is in the AST anywhere
            lineBreaksBefore = noLineBreak;
            lineBreaksAfter = noLineBreak;
            spaceBefore = false;
            spaceAfter = false;
        };
        that.length?.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // "]"
            lineBreaksBefore = noLineBreak;
            spaceBefore = false;
        };
    }
    
    shared actual void visitSimpleType(SimpleType that) {
        that.visitChildren(this);
    }
    
    shared actual void visitSpecifiedArgument(SpecifiedArgument that) {
        value context = fWriter.openContext();
        if (exists id = that.identifier,
            // the typechecker adds synthetic identifiers for anonymous arguments
            id.mainToken exists) {
            id.visit(this);
        }
        that.specifierExpression.visit(this);
        writeSemicolon(fWriter, that.mainEndToken, context);
    }
    
    shared actual void visitSpecifierExpression(SpecifierExpression that) {
        FormattingWriter.FormattingContext? context;
        if (exists mainToken = that.mainToken) {
            context = writeSpecifierMainToken(fWriter, mainToken, options);
        } else {
            context = null;
        }
        that.expression.visit(this);
        if (exists context) {
            fWriter.closeContext(context);
        }
    }
    
    shared actual void visitSpecifierStatement(SpecifierStatement that) {
        value context = fWriter.openContext();
        that.baseMemberExpression.visit(this);
        if (!(that.specifierExpression.mainToken exists)) {
            // for some reason, in some statements the specifier main token ("=" or "=>") is completely missing.
            // it seems that this only happens for the "=" case, so we conjure up the token out of thin air :-/
            // TODO investigate!
            writeSpecifierMainToken(fWriter, "=", options);
        }
        that.specifierExpression.visit(this);
        writeSemicolon(fWriter, that.mainEndToken, context);
    }
    
    shared actual void visitSpreadArgument(SpreadArgument that) {
        value context = fWriter.writeToken {
            that.mainToken; // "*"
            spaceAfter = false; // TODO option?
            lineBreaksAfter = noLineBreak;
        };
        assert (exists context);
        that.expression.visit(this);
        fWriter.closeContext(context);
    }
    
    shared actual void visitSpreadOp(SpreadOp that)
            => writeSomeMemberOp(fWriter, that.mainToken);
    
    shared actual void visitSpreadType(SpreadType that) {
        value context = fWriter.writeToken {
            that.mainToken; // "*"
            spaceAfter = false; // TODO option?
            lineBreaksAfter = noLineBreak;
        };
        assert (exists context);
        that.type.visit(this);
        fWriter.closeContext(context);
    }
    
    shared actual void visitStatement(Statement that) {
        value context = fWriter.openContext();
        that.visitChildren(this);
        if (exists mainEndToken = that.mainEndToken) {
            writeSemicolon(fWriter, mainEndToken, context);
        } else {
            // complex statements like loops, ifs, etc. don’t end in a semicolon
            fWriter.closeContext(context);
        }
    }
    
    shared actual void visitStringTemplate(StringTemplate that) {
        value literals = [*that.stringLiterals];
        value expressions = [*that.expressions];
        "String template must have at least one string literal"
        assert (nonempty literals);
        "String template must have exactly one more string literal than expressions"
        assert (literals.size == expressions.size+1);
        variable Boolean? wantsSpace;
        if (exists expression = expressions.first) {
            wantsSpace = wantsSpacesInStringTemplate(expression.term);
        } else {
            wantsSpace = null;
        }
        fWriter.writeToken {
            literals.first.mainToken;
            spaceBefore = 0;
            spaceAfter = wantsSpace else 0;
        };
        variable value i = 0;
        for (literal in literals.rest) {
            assert (exists expression = expressions[i++]);
            assert (exists previousWantsSpace = wantsSpace);
            Boolean? nextWantsSpace;
            if (exists nextExpression = expressions[i]) {
                nextWantsSpace = wantsSpacesInStringTemplate(nextExpression.term);
            } else {
                nextWantsSpace = null;
            }
            expression.visit(this);
            fWriter.writeToken {
                literal.mainToken;
                spaceBefore = previousWantsSpace;
                spaceAfter = nextWantsSpace else 0;
            };
            wantsSpace = nextWantsSpace;
        }
    }
    
    shared actual void visitSuperType(SuperType that) {
        fWriter.writeToken {
            that.mainToken; // "super"
        };
    }
    
    shared actual void visitSwitchCaseList(SwitchCaseList that) {
        for (caseClause in that.caseClauses) {
            visitCaseClause(caseClause);
        }
        if (exists elseClause = that.elseClause) {
            // a switch else starts on its own line, not on the one of the preceding closing brace
            switchElseNodes.add(elseClause);
            elseClause.visit(this);
            switchElseNodes.remove(elseClause);
        }
    }
    
    shared actual void visitSwitchClause(SwitchClause that) {
        fWriter.writeToken {
            that.mainToken; // "switch"
            spaceAfter = options.spaceAfterControlStructureKeyword;
            lineBreaksAfter = noLineBreak;
        };
        value context = fWriter.writeToken {
            "("; // nowhere in the AST
            spaceAfter = false; // TODO option
            indentAfter = 1;
            lineBreaksAfter = noLineBreak;
        };
        that.switched.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // ")"
            context;
            spaceBefore = false; // TODO option
            lineBreaksBefore = noLineBreak;
            lineBreaksAfter = 0..2;
        };
    }
    
    shared actual void visitSwitchExpression(SwitchExpression that) {
        that.switchClause.visit(this);
        value context = fWriter.openContext(1);
        that.switchCaseList.visit(this);
        fWriter.closeContext(context);
    }
    
    shared actual void visitThenOp(ThenOp that) {
        that.leftTerm.visit(this);
        fWriter.writeToken {
            that.mainToken; // "then"
            indentBefore = 2;
            spaceBefore = true;
            spaceAfter = true;
        };
        that.rightTerm.visit(this);
    }
    
    shared actual void visitThrow(Throw that) {
        value context = fWriter.writeToken {
            that.mainToken; // "throw"
            spaceAfter = 1000;
            lineBreaksAfter = noLineBreak;
        };
        assert (exists context);
        that.expression?.visit(this);
        writeSemicolon(fWriter, that.mainEndToken, context);
    }
    
    shared actual void visitTryClause(TryClause that) {
        fWriter.writeToken {
            that.mainToken; // "try"
            spaceAfter = that.resourceList exists
                    then options.spaceAfterControlStructureKeyword
                    else true;
        };
        that.resourceList?.visit(this);
        that.block.visit(this);
    }
    
    shared actual void visitTuple(Tuple that) {
        value context = fWriter.writeToken {
            that.mainToken; // "["
            spaceAfter = -1000;
            indentAfter = 1;
        };
        that.sequencedArgument?.visit(this); // warning: can be null for the empty tuple []
        fWriter.writeToken {
            that.mainEndToken; // "]"
            context;
            spaceBefore = -1000;
        };
    }
    
    shared actual void visitTuplePattern(TuplePattern that) {
        value context = fWriter.writeToken {
            that.mainToken; // "["
            spaceAfter = -1000;
            indentAfter = 1;
        };
        value patterns = [*that.patterns];
        if (exists firstPattern = patterns.first) {
            firstPattern.visit(this);
            for (pattern in patterns.rest) {
                fWriter.writeToken {
                    ",";
                    spaceBefore = false;
                    spaceAfter = true;
                    lineBreaksBefore = noLineBreak;
                };
                pattern.visit(this);
            }
        }
        fWriter.writeToken {
            that.mainEndToken; // "]"
            context;
            spaceBefore = -1000;
        };
    }
    
    shared actual void visitTupleType(TupleType that) {
        that.typeVariance?.visit(this);
        value context = fWriter.writeToken {
            that.mainToken; // "["
            lineBreaksAfter = noLineBreak;
            spaceAfter = false;
        };
        value elements = [*that.elementTypes];
        if (exists first = elements.first) {
            variable value innerContext = fWriter.openContext();
            first.visit(this);
            for (element in elements.rest) {
                fWriter.writeToken {
                    ",";
                    lineBreaksBefore = noLineBreak;
                    spaceBefore = false;
                    spaceAfter = true;
                    innerContext;
                };
                innerContext = fWriter.openContext(1);
                element.visit(this);
            }
        }
        fWriter.writeToken {
            that.mainEndToken; // "]"
            lineBreaksBefore = noLineBreak;
            spaceBefore = false;
            context = context;
        };
    }
    
    shared actual void visitTypeAliasDeclaration(TypeAliasDeclaration that) {
        that.annotationList.visit(this);
        value context = fWriter.writeToken {
            that.mainToken; // "alias"
            spaceBefore = true;
            spaceAfter = true;
            lineBreaksAfter = noLineBreak;
        };
        assert (exists context);
        that.identifier.visit(this);
        that.typeParameterList?.visit(this);
        that.typeConstraintList?.visit(this);
        that.typeSpecifier?.visit(this);
        writeSemicolon(fWriter, that.mainEndToken, context);
    }
    
    shared actual void visitTypeArgumentList(TypeArgumentList that) {
        writeTypeArgumentOrParameterList(fWriter, this, that, options);
    }
    
    shared actual void visitTypeConstraint(TypeConstraint that) {
        value context = fWriter.writeToken {
            that.mainToken; // "given"
            spaceAfter = true;
            indentBefore = options.indentBeforeTypeInfo;
            indentAfter = options.indentBeforeTypeInfo;
            lineBreaksBefore = 1..0;
        };
        assert (exists context);
        that.identifier.visit(this);
        that.typeParameterList?.visit(this);
        that.caseTypes?.visit(this);
        that.satisfiedTypes?.visit(this);
        that.abstractedType?.visit(this);
        fWriter.closeContext(context);
    }
    
    shared actual void visitTypeConstraintList(TypeConstraintList that) {
        that.typeConstraints*.visit(this);
    }
    
    shared actual void visitTypeConstructor(TypeConstructor that) {
        that.typeParameterList.visit(this);
        that.typeConstraintList?.visit(this);
        fWriter.writeToken {
            "=>"; // not in the AST
            spaceBefore = true;
            spaceAfter = true;
            lineBreaksBefore = 0..1;
            lineBreaksAfter = noLineBreak;
        };
        that.type.visit(this);
    }
    
    shared actual void visitTypedDeclaration(TypedDeclaration that) {
        that.annotationList?.visit(this);
        that.type.visit(this);
        that.identifier.visit(this);
    }
    
    shared actual void visitTypeOperatorExpression(TypeOperatorExpression that) {
        that.term.visit(this);
        fWriter.writeToken {
            that.mainToken; // "is", "extends", "satisfies" or "of"
            spaceBefore = true;
            spaceAfter = true;
            lineBreaksBefore = noLineBreak;
            lineBreaksAfter = noLineBreak;
        };
        that.type.visit(this);
    }
    
    shared actual void visitTypeParameterDeclaration(TypeParameterDeclaration that) {
        that.typeVariance?.visit(this);
        that.identifier.visit(this);
        visitingDefaultTypeArgument = true;
        that.typeSpecifier?.visit(this);
        visitingDefaultTypeArgument = false;
    }
    
    shared actual void visitTypeParameterList(TypeParameterList that) {
        writeTypeArgumentOrParameterList(fWriter, this, that, options);
    }
    
    shared actual void visitTypeParameterLiteral(TypeParameterLiteral that)
            => writeMetaLiteral(fWriter, this, that, "given");
    
    shared actual void visitTypeSpecifier(TypeSpecifier that) {
        /*
         used for aliasy things (class =>, interface =>, alias =>)
         and for default type arguments
         */
        Boolean spaces = visitingDefaultTypeArgument then options.spaceAroundTypeParamListEqualsSign else true;
        visitingDefaultTypeArgument = false;
        value context = fWriter.writeToken {
            that.mainToken; // "=>" or "="
            spaceBefore = spaces;
            spaceAfter = spaces;
            indentBefore = 2;
            indentAfter = 1;
            lineBreaksBefore = that.mainToken.text == "=>" then 0..1 else noLineBreak;
            lineBreaksAfter = spaces then 0..1 else noLineBreak;
        };
        that.type.visit(this);
        assert (exists context);
        fWriter.closeContext(context);
    }
    
    shared actual void visitTypeVariance(TypeVariance that)
            => writeModifier(fWriter, that.mainToken); // "in" or "out"
    
    shared actual void visitUnionType(UnionType that) {
        that.typeVariance?.visit(this);
        value types = [*that.staticTypes];
        "Empty union type not allowed"
        assert (nonempty types);
        types.first.visit(this);
        for (type in types.rest) {
            fWriter.writeToken {
                "|";
                lineBreaksBefore = noLineBreak;
                lineBreaksAfter = noLineBreak;
                spaceBefore = false;
                spaceAfter = false;
            };
            type.visit(this);
        }
    }
    
    shared actual void visitValueIterator(ValueIterator that) {
        value context = fWriter.writeToken {
            that.mainToken; // "("
            spaceAfter = options.spaceAfterValueIteratorOpeningParenthesis;
            lineBreaksAfter = noLineBreak;
        };
        that.variable.visit(this);
        that.specifierExpression.visit(this);
        fWriter.writeToken {
            that.mainEndToken; // ")"
            context;
            spaceBefore = options.spaceBeforeValueIteratorClosingParenthesis;
            lineBreaksBefore = noLineBreak;
        };
    }
    
    shared actual void visitValueLiteral(ValueLiteral that)
            => writeMetaLiteral(fWriter, this, that, "value");
    
    shared actual void visitValueModifier(ValueModifier that) {
        if (exists mainToken = that.mainToken) {
            writeModifier(fWriter, mainToken);
        } else {
            // the variables in a for (x in xs, y in ys) apparently have a ValueModifier without token
        }
    }
    
    shared actual void visitVariable(Variable that) {
        if (that is GuardedVariable) {
            // the compiler inserts GuardedVariable nodes after blocks that definitely return, see ceylon/ceylon-spec#891.
            // these aren’t present in the source code of course, so we should skip them.
            return;
        }
        that.annotationList?.visit(this);
        that.type.visit(this);
        that.identifier.visit(this);
        for (list in that.parameterLists) {
            list.visit(this);
        }
        if (exists t = that.specifierExpression?.mainToken) {
            that.specifierExpression.visit(this);
        } else {
            /*
             ignore; for a condition like
                 if (exists something)
             (without a specifier expression), the compiler just adds the identifier as expression
             in which case we shouldn’t visit this “virtual” expression
             (see #27)
             */
        }
    }
    
    shared actual void visitVariablePattern(VariablePattern that) {
        that.variable.visit(this);
    }
    
    shared actual void visitVoidModifier(VoidModifier that) {
        if (exists token = that.mainToken) {
            writeModifier(fWriter, token);
        }
    }
    
    shared actual void visitWhileClause(WhileClause that) {
        fWriter.writeToken {
            that.mainToken; // "while"
            spaceAfter = options.spaceAfterControlStructureKeyword;
            lineBreaksAfter = noLineBreak;
        };
        that.conditionList.visit(this);
        that.block.visit(this);
    }
    
    shared actual void visitWithinOp(WithinOp that) {
        that.lowerBound.visit(this);
        fWriter.writeToken {
            that.lowerBound is OpenBound then "<" else "<="; // no, there is no better way to get this information
            spaceBefore = true;
            spaceAfter = true;
        };
        that.term.visit(this);
        fWriter.writeToken {
            that.upperBound is OpenBound then "<" else "<=";
            spaceBefore = true;
            spaceAfter = true;
        };
        that.upperBound.visit(this);
    }
    
    //TODO eventually, this will be unneeded, as each visitSomeSubclassOfNode should be overwritten here.
    shared actual void visitAny(Node that) {
        if (that.mainToken exists || that.mainEndToken exists) {
            process.writeErrorLine("`` that.mainToken?.text else "" ``\t`` that.mainEndToken?.text else "" ``"); // breakpoint here
        }
        super.visitAny(that); // continue walking the tree
    }
    
    shared actual void destroy(Throwable? error) {
        fWriter.destroy(error);
        writer.destroy(error);
    }
}
