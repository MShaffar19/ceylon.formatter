void   testFunctionArguments   ()                                                               {
    "abC". any( (Character c)=>c. integerValue>10)                                                       ;
    variable Integer i = 1                                                                               ;
    "1 2 fizz 4 buzz fizz 7 8 fizz buzz 11 fizz 13 14 fizzbuzz". split(). every(   (String s)   {
        value        j = i    ++                                                                         ;
        if (j % 15==0)                                                                          {
            return   s   =="fizzbuzz"                                                                    ;
}
        if (j % 5==0)                                                                           {
            return   s   =="buzz"                                                                        ;
}
        if (j % 3==0)                                                                           {
            return   s   =="fizz"                                                                        ;
}
            return   s   ==j. string                                                                     ;
}    )                                                                                                   ;
}