void testIndexExpressions() {
    value v1 = process.arguments [ 0 ] ;
    value v2 = process.arguments [ 6 / 3 ];
    value v3 = process.arguments [ 0 .. 1 ];
    value v4 = process.arguments [ 2 : 2 ];
    value v5 = process.arguments [ 1 ... ];
    value v6 = process.arguments [ ... 3 ];
}
