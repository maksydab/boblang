const std = @import("std");

const TestCase = struct {
    name: []const u8,
    program: []const u8,
    expected: []const u8,
};

const test_cases = [_]TestCase{
    .{
        .name = "arithmetic",
        .program =
        \\print(1 + 2)
        \\print(10 - 4)
        \\print(3 * 4)
        \\print(15 / 3)
        \\print(1 + 2 * 3)
        \\print((1 + 2) * 3)
        ,
        .expected =
        \\3
        \\6
        \\12
        \\5
        \\7
        \\9
        ,
    },
    .{
        .name = "booleans",
        .program =
        \\print(True)
        \\print(False)
        \\print(1 == 1)
        \\print(1 == 2)
        ,
        .expected =
        \\true
        \\false
        \\true
        \\false
        ,
    },
    .{
        .name = "strings",
        .program =
        \\print("hello")
        \\print("hello", "world")
        ,
        .expected =
        \\hello
        \\hello world
        ,
    },
    .{
        .name = "variables",
        .program =
        \\x = 42
        \\print(x)
        \\x = 100
        \\print(x)
        \\y = "test"
        \\print(y)
        ,
        .expected =
        \\42
        \\100
        \\test
        ,
    },
    .{
        .name = "conditionals",
        .program =
        \\if (1 == 1):
        \\    print("if_true")
        \\if (1 == 2):
        \\    print("if_false")
        \\else:
        \\    print("else_worked")
        \\if (1 == 2):
        \\    print("if_bad")
        \\elif (1 == 1):
        \\    print("elif_worked")
        \\else:
        \\    print("else_bad")
        ,
        .expected =
        \\if_true
        \\else_worked
        \\elif_worked
        ,
    },
    .{
        .name = "for_loop",
        .program =
        \\for i in range(3):
        \\    print(i)
        ,
        .expected =
        \\0
        \\1
        \\2
        ,
    },
    .{
        .name = "while_loop",
        .program =
        \\x = 100
        \\while (x == 100):
        \\    print("while_ran")
        \\    x = 0
        ,
        .expected =
        \\while_ran
        ,
    },
    .{
        .name = "lists",
        .program =
        \\print([1, 2, 3])
        \\lst = [4, 5, 6]
        \\print(lst)
        ,
        .expected =
        \\[1, 2, 3]
        \\[4, 5, 6]
        ,
    },
    .{
        .name = "dicts",
        .program =
        \\print({"a": 1, "b": 2})
        \\d = {}
        \\d["key"] = "val"
        \\print(d)
        ,
        .expected =
        \\{a: 1, b: 2}
        \\{key: val}
        ,
    },
    .{
        .name = "type_conversions",
        .program =
        \\print(int("7"))
        \\print(str(42))
        \\print(type(1))
        \\print(type("hi"))
        \\print(type(True))
        ,
        .expected =
        \\7
        \\42
        \\int
        \\str
        \\bool
        ,
    },
    .{
        .name = "range",
        .program =
        \\print(range(0, 10, 3))
        ,
        .expected =
        \\[0, 3, 6, 9]
        ,
    },
    .{
        .name = "classes",
        .program =
        \\class Animal:
        \\    func _init_(name):
        \\        self.name = name
        \\    func speak():
        \\        print("My name is", self.name)
        \\a = Animal("Fluffy")
        \\a.speak()
        ,
        .expected =
        \\My name is Fluffy
        ,
    },
    .{
        .name = "inheritance",
        .program =
        \\class Animal:
        \\    func _init_(name):
        \\        self.name = name
        \\    func speak():
        \\        print("My name is", self.name)
        \\class Dog(Animal):
        \\    func _init_(_prev_, breed):
        \\        self.breed = breed
        \\    func bark():
        \\        print("Bark from", self.breed)
        \\d = Dog("Buddy", "Husky")
        \\d.bark()
        \\d.speak()
        ,
        .expected =
        \\Bark from Husky
        \\My name is nil
        ,
    },
    .{
        .name = "nested_blocks",
        .program =
        \\if (1 == 1):
        \\    if (2 == 2):
        \\        print("nested")
        ,
        .expected =
        \\nested
        ,
    },
    .{
        .name = "augmented_assign",
        .program =
        \\n = 5
        \\n += 3
        \\print(n)
        \\n *= 2
        \\print(n)
        ,
        .expected =
        \\8
        \\16
        ,
    },
    .{
        .name = "try_except",
        .program =
        \\try:
        \\    print("try_body")
        \\except:
        \\    print("except_body")
        \\print("after_try")
        \\try:
        \\    p = 99
        \\    print(p)
        \\except:
        \\    print("should_not_run")
        \\
        ,
        .expected =
        \\try_body
        \\after_try
        \\99
        ,
    },
    .{
        .name = "c_import",
        .program =
        \\import src/tests/stuff/test_math.c as math
        \\print(math.add_ints(10, 5))
        \\print(math.sub_ints(20, 7))
        \\print(math.mul_ints(3, 4))
        \\print(math.double_int(21))
        \\
        ,
        .expected =
        \\15
        \\13
        \\12
        \\42
        ,
    },
    .{
        .name = "boblang_import",
        .program =
        \\import src.tests.stuff.test_module as test_mod
        \\x = test_mod.add(40, 2)
        \\print(x)
        ,
        .expected =
        \\42
        ,
    },
    .{
        .name = "private_func",
        .program =
        \\class MyClass:
        \\    private func helper():
        \\        return 42
        \\    func _init_():
        \\        print("created")
        \\    func get_val():
        \\        return 99
        \\obj = MyClass()
        \\print(obj.get_val())
        ,
        .expected =
        \\created
        \\99
        ,
    },
    .{
        .name = "chained_call",
        .program =
        \\class MyClass:
        \\    func foo(x):
        \\        return x + 1
        \\print(MyClass().foo(5))
        ,
        .expected =
        \\6
        ,
    },
    .{
        .name = "boolean_ops",
        .program =
        \\print(True and True)
        \\print(True and False)
        \\print(False and True)
        \\print(False and False)
        \\print(True or False)
        \\print(False or True)
        \\print(False or False)
        ,
        .expected =
        \\true
        \\false
        \\false
        \\false
        \\true
        \\true
        \\false
        ,
    },
    .{
        .name = "fibonacci",
        .program =
        \\n = 10
        \\a = 0
        \\b = 1
        \\while n > 0:
        \\    print(a)
        \\    c = a + b
        \\    a = b
        \\    b = c
        \\    n = n - 1
        ,
        .expected =
        \\0
        \\1
        \\1
        \\2
        \\3
        \\5
        \\8
        \\13
        \\21
        \\34
        ,
    },
    .{
        .name = "factorial",
        .program =
        \\n = 7
        \\r = 1
        \\while n > 0:
        \\    r = r * n
        \\    n = n - 1
        \\print(r)
        ,
        .expected =
        \\5040
        ,
    },
    .{
        .name = "collatz",
        .program =
        \\n = 27
        \\steps = 0
        \\while n > 1:
        \\    if n % 2 == 0:
        \\        n = n / 2
        \\    else:
        \\        n = 3 * n + 1
        \\    steps = steps + 1
        \\print(steps)
        ,
        .expected =
        \\111
        ,
    },
    .{
        .name = "gcd",
        .program =
        \\a = 48
        \\b = 18
        \\while b != 0:
        \\    t = b
        \\    b = a % b
        \\    a = t
        \\print(a)
        ,
        .expected =
        \\6
        ,
    },
    .{
        .name = "sorting",
        .program =
        \\arr = [5, 3, 8, 1, 9, 2]
        \\i = 0
        \\while i < 6:
        \\    j = i + 1
        \\    while j < 6:
        \\        if arr[j] < arr[i]:
        \\            t = arr[i]
        \\            arr[i] = arr[j]
        \\            arr[j] = t
        \\        j = j + 1
        \\    i = i + 1
        \\print(arr)
        ,
        .expected =
        \\[1, 2, 3, 5, 8, 9]
        ,
    },
    .{
        .name = "palindrome",
        .program =
        \\s = "racecar"
        \\i = 0
        \\j = len(s) - 1
        \\is_pal = True
        \\while i < j:
        \\    if s[i] != s[j]:
        \\        is_pal = False
        \\        break
        \\    i = i + 1
        \\    j = j - 1
        \\print(is_pal)
        ,
        .expected =
        \\true
        ,
    },
    .{
        .name = "sum_of_squares",
        .program =
        \\n = 10
        \\s = 0
        \\while n > 0:
        \\    s = s + n * n
        \\    n = n - 1
        \\print(s)
        ,
        .expected =
        \\385
        ,
    },
    .{
        .name = "utils",
        .program =
        \\print("pow")
        \\print(2 ** 3)
        \\print(2 ^ 3)
        \\print("int_div")
        \\print(10 // 3)
        \\print("builtins")
        \\print(min(5, 3))
        \\print(max(5, 3))
        \\print(clamp(5, 0, 3))
        \\print(chr(65))
        \\print(ascii("A"))
        \\print("slice")
        \\s = "hello"
        \\print(s[1:3])
        \\print("sort")
        \\l = [3, 1, 2]
        \\l.sort()
        \\print(l)
        \\print("power_chain")
        \\print(2 ** 3 ** 2)
        ,
        .expected =
        \\pow
        \\8
        \\8
        \\int_div
        \\3
        \\builtins
        \\3
        \\5
        \\3
        \\A
        \\65
        \\slice
        \\el
        \\sort
        \\[1, 2, 3]
        \\power_chain
        \\512
        ,
    },
    .{
        .name = "gc_stress",
        .program =
        \\print("gc_stress")
        \\i = 0
        \\while i < 500:
        \\    l = [1, 2, 3, 4, 5]
        \\    j = 0
        \\    while j < 50:
        \\        l = [j, j + 1, j + 2]
        \\        s = str(j)
        \\        j = j + 1
        \\    i = i + 1
        \\print("done")
        ,
        .expected =
        \\gc_stress
        \\done
        ,
    },
    .{
        .name = "comparison_ops",
        .program =
        \\print(1 < 2)
        \\print(1 > 2)
        \\print(1 <= 1)
        \\print(1 >= 2)
        \\print(1 != 1)
        \\print(1 != 2)
        ,
        .expected =
        \\true
        \\false
        \\true
        \\false
        \\false
        \\true
        ,
    },
    .{
        .name = "func_decorator",
        .program =
        \\func my_decorator(f):
        \\    print("decorated")
        \\    return f
        \\@my_decorator
        \\func foo():
        \\    print("foo")
        \\print("after")
        \\foo()
        ,
        .expected =
        \\decorated
        \\after
        \\foo
        ,
    },
    .{
        .name = "multi_decorator",
        .program =
        \\func add_hello(f):
        \\    print("hello")
        \\    return f
        \\func add_world(f):
        \\    print("world")
        \\    return f
        \\@add_hello
        \\@add_world
        \\func foo():
        \\    print("foo")
        \\print("after")
        \\foo()
        ,
        .expected =
        \\world
        \\hello
        \\after
        \\foo
        ,
    },
    .{
        .name = "class_decorator",
        .program =
        \\func add_decorator(cls):
        \\    print("class_decorated")
        \\    return cls
        \\@add_decorator
        \\class MyClass:
        \\    func _init_():
        \\        print("init")
        \\print("after")
        \\obj = MyClass()
        ,
        .expected =
        \\class_decorated
        \\after
        \\init
        ,
    },
    .{
        .name = "const_propagation",
        .program =
        \\x = 42
        \\print(x)
        ,
        .expected =
        \\42
        ,
    },
    .{
        .name = "chain_flatten",
        .program =
        \\a = 7
        \\b = a
        \\c = b
        \\print(c)
        ,
        .expected =
        \\7
        ,
    },
    .{
        .name = "fold_then_prop",
        .program =
        \\x = 10
        \\y = x + 5
        \\print(y)
        ,
        .expected =
        \\15
        ,
    },
    .{
        .name = "control_flow_tracking",
        .program =
        \\x = 5
        \\if (True):
        \\    y = x + 3
        \\    print(y)
        \\print(x + 7)
        ,
        .expected =
        \\8
        \\12
        ,
    },
    .{ .name = "float_display", .program = 
    \\print(1.5 + 1.5)
    \\print(0.1 + 0.2)
    \\print(3.0)
    \\print(0.5 * 2)
    \\
    , .expected = 
    \\3.0
    \\0.3
    \\3.0
    \\1.0
    \\
    },
    .{ .name = "float_ops", .program = 
    \\print(0.01 + 0.02)
    \\print(1.5 - 0.5)
    \\print(2.0 * 3.0)
    \\print(7.0 / 2.0)
    \\print(10.0 / 3)
    \\
    , .expected = 
    \\0.03
    \\1.0
    \\6.0
    \\3.5
    \\3.33333
    \\
    },
    .{ .name = "type_conversions_full", .program = 
    \\print(int(3.7))
    \\print(int("42"))
    \\print(float(3))
    \\print(float("3.14"))
    \\print(str(42))
    \\print(str(3.14))
    \\print(bool(1))
    \\print(bool(0))
    \\print(bool("true"))
    \\print(bool(""))
    \\
    , .expected = 
    \\3
    \\42
    \\3.0
    \\3.14
    \\42
    \\3.14
    \\true
    \\false
    \\true
    \\false
    \\
    },
    .{ .name = "list_sort_mixed", .program = 
    \\l = [3, 1, 2]
    \\print(l.sort())
    \\l2 = ["c", "a", "b"]
    \\print(l2.sort())
    \\l3 = [True, False, 1, 0]
    \\print(l3.sort())
    \\l4 = [[5, 1], [3, 9], [1]]
    \\print(l4.sort())
    \\l5 = [3.5, 2, 1.5, True, False]
    \\print(l5.sort())
    \\
    , .expected = 
    \\[1, 2, 3]
    \\[a, b, c]
    \\[false, 0, true, 1]
    \\[[1], [3, 9], [5, 1]]
    \\[false, true, 1.5, 2, 3.5]
    \\
    },
    .{ .name = "list_methods", .program = 
    \\l = [1, 2, 3]
    \\l.append(4)
    \\print(l)
    \\print(l.pop())
    \\print(l)
    \\l.reverse()
    \\print(l)
    \\l.clear()
    \\print(l)
    \\
    , .expected = 
    \\[1, 2, 3, 4]
    \\4
    \\[1, 2, 3]
    \\[3, 2, 1]
    \\[]
    \\
    },
    .{ .name = "dict_ops_full", .program = 
    \\d = {"a": 1, "b": 2}
    \\print(d["a"])
    \\print(len(d))
    \\d["c"] = 3
    \\print(d["c"])
    \\
    , .expected = 
    \\1
    \\2
    \\3
    \\
    },
    .{ .name = "nested_types", .program = 
    \\m = [[1, 2], [3, 4]]
    \\print(m[0])
    \\print(m[0][1])
    \\d = {"list": [1, 2, 3]}
    \\print(d["list"])
    \\
    , .expected = 
    \\[1, 2]
    \\2
    \\[1, 2, 3]
    \\
    },
    .{ .name = "type_func", .program = 
    \\print(type(1))
    \\print(type(1.5))
    \\print(type("hello"))
    \\print(type(True))
    \\print(type([1, 2]))
    \\print(type({"a": 1}))
    \\
    , .expected = 
    \\int
    \\float
    \\str
    \\bool
    \\list
    \\dict
    \\
    },
    .{ .name = "augmented_ops_full", .program = 
    \\x = 5
    \\x += 3
    \\print(x)
    \\y = 3
    \\y *= 4
    \\print(y)
    \\
    , .expected = 
    \\8
    \\12
    \\
    },
    .{ .name = "list_slice_copy", .program = 
    \\l = [1, 2, 3]
    \\u = l[:]
    \\l.append(4)
    \\print(u)
    \\print(l)
    \\v = l[2:]
    \\print(v)
    \\w = l[1:3]
    \\print(w)
    \\s = "hello"
    \\print(s[1:3])
    \\
    , .expected = 
    \\[1, 2, 3]
    \\[1, 2, 3, 4]
    \\[3, 4]
    \\[2, 3]
    \\el
    \\
    },
    .{ .name = "list_slice_assign", .program = 
    \\l = [1, 2, 3, 4, 5]
    \\l[1:3] = [9, 8]
    \\print(l)
    \\m = [1, 2, 3]
    \\m[:] = [7]
    \\print(m)
    \\n = [1, 2, 3]
    \\n[1:1] = [6]
    \\print(n)
    \\
    , .expected = 
    \\[1, 9, 8, 4, 5]
    \\[7]
    \\[1, 6, 2, 3]
    \\
    },
    .{ .name = "except_var", .program = 
    \\try:
    \\    risky = int("notanumber")
    \\except e:
    \\    print("caught:", e)
    \\print("after")
    \\
    , .expected = 
    \\caught: Runtime Error: int() requires a valid integer string, but the input could not be fully parsed as a number.
    \\after
    \\
    },
    .{ .name = "nullable_assign_caught", .program = 
    \\func returnsnull():
    \\    return nil
    \\
    \\try:
    \\    x = returnsnull()
    \\except e:
    \\    print("null caught:", e)
    \\print("after")
    \\
    , .expected = 
    \\null caught: cannot assign nil to non-nullable variable 'x'
    \\after
    \\
    },
    .{ .name = "nullable_var", .program = 
    \\func returnsnull():
    \\    return nil
    \\
    \\x? = returnsnull()
    \\y = 5
    \\print("x:", x)
    \\print("y:", y)
    \\
    , .expected = 
    \\x: nil
    \\y: 5
    \\
    },
    .{ .name = "type_mismatch_caught", .program = 
    \\func getstr():
    \\    return "str"
    \\
    \\try:
    \\    x: int = 0
    \\    x = getstr()
    \\except e:
    \\    print("type caught:", e)
    \\print("after")
    \\
    , .expected = 
    \\type caught: Type Mismatch: variable 'x' expected int, got str
    \\after
    \\
    },
    .{ .name = "float_cast_fraction", .program = 
    \\func add(a:float, b:float):
    \\    return a+b
    \\print(add(float("123.4"), 2))
    \\g: float = float("99.5")
    \\print(g)
    \\
    , .expected = 
    \\125.4
    \\99.5
    \\
    },
    .{ .name = "lowercase_bools", .program = 
    \\print(true)
    \\print(false)
    \\b: bool = true
    \\print(b)
    \\
    , .expected = 
    \\true
    \\false
    \\true
    \\
    },
    .{ .name = "typed_list_params", .program = 
    \\func f(x: list[int]):
    \\    return len(x)
    \\print(f([1,2,3]))
    \\func g() list[int] :
    \\    return [1,2]
    \\print(g())
    \\func h(x: list[str]):
    \\    return x[0]
    \\print(h(["a","b"]))
    \\
    , .expected = 
    \\3
    \\[1, 2]
    \\a
    \\
    },
    .{ .name = "typed_bool_list_lowercase", .program = 
    \\b: list[bool] = [true, false]
    \\print(b[0])
    \\print(b[1])
    \\print(len(b))
    \\
    , .expected = 
    \\1
    \\0
    \\2
    \\
    },
    .{ .name = "big_numbers", .program = 
    \\a: bigi = 123456789012345678901234
    \\print(a)
    \\print(a + 1)
    \\print(a - 1)
    \\print(a * 2)
    \\print(a // 2)
    \\print(a % 3)
    \\print(a > 1)
    \\print(a == 123456789012345678901234)
    \\b: bigf = 3.141592653589793238462643383279
    \\print(b)
    \\print(b + 1)
    \\print(b * 2)
    \\print(b + 0.5)
    \\print(b < 10)
    \\n: bigi = -123456789012345678901234
    \\print(n)
    \\big: bigi = 40 + 2
    \\print(big)
    \\f: bigf = 1.5 + 2.5
    \\print(f)
    \\i: int = a
    \\print(i)
    \\g: float = b
    \\print(g)
    \\print(type(a))
    \\print(type(b))
    \\
    , .expected = 
    \\123456789012345678901234
    \\123456789012345678901235
    \\123456789012345678901233
    \\246913578024691357802468
    \\61728394506172839450617
    \\1
    \\true
    \\true
    \\3.141592653589793238462643383279
    \\4.141592653589793238462643383279
    \\6.283185307179586476925286766558
    \\3.641592653589793238462643383279
    \\true
    \\-123456789012345678901234
    \\42
    \\4
    \\1954299044504711154
    \\3.14159
    \\bigi
    \\bigf
    \\
    },
    .{ .name = "enum_value_types", .program = 
    \\enum color { R = "red", G = "green", B = "blue" }
    \\print(color.G)
    \\print(type(color.B))
    \\c: color = color.G
    \\print(c)
    \\enum num { A = 5, B = 3.14, C = true, D }
    \\print(num.A)
    \\print(num.B)
    \\print(num.C)
    \\print(num.D)
    \\enum mixed { X, Y = "hi", Z }
    \\print(mixed.X)
    \\print(mixed.Y)
    \\print(mixed.Z)
    \\enum flags { Alpha, Beta = 100, Gamma, Delta = -1, Epsilon }
    \\print(flags.Alpha)
    \\print(flags.Beta)
    \\print(flags.Gamma)
    \\print(flags.Delta)
    \\print(flags.Epsilon)
    \\enum csv { A = "a,b,c" }
    \\print(csv.A)
    \\enum listy { Nums = [1, 2, 3] }
    \\print(len(listy.Nums))
    \\enum other { P = 10, Q }
    \\enum ref { One = other.P }
    \\print(ref.One)
    \\print(type(flags.Beta))
    \\
    , .expected = 
    \\green
    \\str
    \\green
    \\5
    \\3.14
    \\true
    \\6
    \\0
    \\hi
    \\1
    \\0
    \\100
    \\101
    \\-1
    \\0
    \\a,b,c
    \\3
    \\10
    \\int
    \\
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const compiler_bin = if (std.os.argv.len > 1)
        std.mem.sliceTo(std.os.argv[1], 0)
    else
        "zig-out/bin/boblang";

    var total_passed: usize = 0;
    var total_failed: usize = 0;

    for (test_cases) |tc| {
        const test_file = "test_compile_temp.bob";
        std.fs.cwd().deleteFile("output.ll") catch {};
        std.fs.cwd().deleteFile("output") catch {};
        try std.fs.cwd().writeFile(.{ .sub_path = test_file, .data = tc.program });

        const compile_argv = &[_][]const u8{ compiler_bin, "build", test_file, "-o", "output" };
        var compile_child = std.process.Child.init(compile_argv, allocator);
        compile_child.stdout_behavior = .Pipe;
        compile_child.stderr_behavior = .Pipe;
        try compile_child.spawn();

        var compile_out = std.ArrayList(u8).init(allocator);
        defer compile_out.deinit();
        var compile_err = std.ArrayList(u8).init(allocator);
        defer compile_err.deinit();

        if (compile_child.stdout) |out| try out.reader().readAllArrayList(&compile_out, 1024 * 1024);
        if (compile_child.stderr) |err| try err.reader().readAllArrayList(&compile_err, 1024 * 1024);

        const compile_term = try compile_child.wait();
        if (compile_term != .Exited or compile_term.Exited != 0) {
            std.debug.print("[FAIL] [{s}] compilation failed with exit code {}\n", .{ tc.name, compile_term });
            std.debug.print("  stderr: {s}\n", .{compile_err.items});
            total_failed += 1;
            std.fs.cwd().deleteFile(test_file) catch {};
            continue;
        }

        const run_argv = &[_][]const u8{"./output"};
        var run_child = std.process.Child.init(run_argv, allocator);
        run_child.stdout_behavior = .Pipe;
        run_child.stderr_behavior = .Pipe;
        try run_child.spawn();

        var run_out = std.ArrayList(u8).init(allocator);
        defer run_out.deinit();

        if (run_child.stdout) |out| try out.reader().readAllArrayList(&run_out, 1024 * 1024);

        const run_term = try run_child.wait();
        if (run_term != .Exited or run_term.Exited != 0) {
            std.debug.print("[FAIL] [{s}] runtime exited with code {}\n", .{ tc.name, run_term });
            total_failed += 1;
            std.fs.cwd().deleteFile(test_file) catch {};
            continue;
        }

        const actual = std.mem.trim(u8, run_out.items, "\n\r\t ");
        const expected = std.mem.trim(u8, tc.expected, "\n\r\t ");

        if (std.mem.eql(u8, actual, expected)) {
            total_passed += 1;
            std.debug.print("[PASS] [{s}]\n", .{tc.name});
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [{s}] output mismatch\n", .{tc.name});
            std.debug.print("  expected\n{s}\n", .{expected});
            std.debug.print("  actual\n{s}\n", .{actual});

            var exp_it = std.mem.splitSequence(u8, expected, "\n");
            var act_it = std.mem.splitSequence(u8, actual, "\n");
            var line_num: usize = 1;
            while (true) {
                const e_line = exp_it.next();
                const a_line = act_it.next();
                if (e_line == null and a_line == null) break;
                const e_str = e_line orelse "(missing)";
                const a_str = a_line orelse "(missing)";
                if (!std.mem.eql(u8, e_str, a_str)) {
                    std.debug.print("    line {d}: expected '{s}', got '{s}'\n", .{ line_num, e_str, a_str });
                }
                line_num += 1;
            }
        }

        std.fs.cwd().deleteFile(test_file) catch {};
    }

    std.fs.cwd().deleteFile("output.ll") catch {};
    std.fs.cwd().deleteFile("output") catch {};
    std.fs.cwd().deleteFile("output_cross") catch {};
    std.fs.cwd().deleteFile("output_cross.exe") catch {};
    std.fs.cwd().deleteFile("output_cross.pdb") catch {};
    std.fs.cwd().deleteFile("output_cross.wasm") catch {};
    std.fs.cwd().deleteFile("output_cross.ll") catch {};
    std.fs.cwd().deleteFile("test_cross_temp.bob") catch {};
    std.fs.cwd().deleteFile("test_compile_temp.bob") catch {};

    const cross_test_cases = [_]struct {
        name: []const u8,
        target: []const u8,
    }{
        .{ .name = "wasm32", .target = "--wasm" },
        .{ .name = "aarch64_linux", .target = "--arch aarch64 --os linux" },
        .{ .name = "x86_64_windows", .target = "--windows" },
        .{ .name = "x86_64_macos", .target = "--macos" },
        .{ .name = "arm_linux", .target = "--arch arm --os linux" },
    };

    for (cross_test_cases) |ctc| {
        const test_file = "test_cross_temp.bob";
        std.fs.cwd().deleteFile("output.ll") catch {};
        std.fs.cwd().deleteFile("output*") catch {};
        try std.fs.cwd().writeFile(.{ .sub_path = test_file, .data = "x=1\nprint(x)" });

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();
        try args.append(compiler_bin);
        try args.append("build");
        try args.append(test_file);
        var target_it = std.mem.splitSequence(u8, ctc.target, " ");
        while (target_it.next()) |part| try args.append(part);
        try args.append("-o");
        try args.append("output_cross");

        var compile_child = std.process.Child.init(args.items, allocator);
        compile_child.stdout_behavior = .Pipe;
        compile_child.stderr_behavior = .Pipe;
        try compile_child.spawn();

        var compile_err = std.ArrayList(u8).init(allocator);
        defer compile_err.deinit();
        if (compile_child.stderr) |err| try err.reader().readAllArrayList(&compile_err, 1024 * 1024);

        const compile_term = try compile_child.wait();
        if (compile_term == .Exited and compile_term.Exited == 0) {
            total_passed += 1;
            std.debug.print("[PASS] [{s}]\n", .{ctc.name});
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [{s}] cross-compilation failed with exit code {}\n", .{ ctc.name, compile_term });
            std.debug.print("  stderr: {s}\n", .{compile_err.items});
        }

        std.fs.cwd().deleteFile(test_file) catch {};
        std.fs.cwd().deleteFile("output_cross") catch {};
        std.fs.cwd().deleteFile("output_cross.exe") catch {};
        std.fs.cwd().deleteFile("output_cross.pdb") catch {};
        std.fs.cwd().deleteFile("output_cross.wasm") catch {};
        std.fs.cwd().deleteFile("output_cross.ll") catch {};
    }

    // obfuscation tests
    {
        const obf_program =
            \\func greet(name):
            \\    return "hello " + name
            \\secret = "S3CR3T_MARKER_XYZZY"
            \\print(secret)
            \\print(greet("bob"))
            \\try:
            \\    bad = int("notanumber")
            \\except e:
            \\    print("caught")
            \\print("done")
        ;
        const obf_file = "test_obf_temp.bob";
        std.fs.cwd().deleteFile("output_obf") catch {};
        std.fs.cwd().deleteFile("output_obf.ll") catch {};
        try std.fs.cwd().writeFile(.{ .sub_path = obf_file, .data = obf_program });

        var obf_args = std.ArrayList([]const u8).init(allocator);
        defer obf_args.deinit();
        try obf_args.append(compiler_bin);
        try obf_args.append("build");
        try obf_args.append(obf_file);
        try obf_args.append("--obfuscate");
        try obf_args.append("-o");
        try obf_args.append("output_obf");

        var obf_child = std.process.Child.init(obf_args.items, allocator);
        obf_child.stdout_behavior = .Pipe;
        obf_child.stderr_behavior = .Pipe;
        try obf_child.spawn();
        var obf_err = std.ArrayList(u8).init(allocator);
        defer obf_err.deinit();
        if (obf_child.stderr) |err| try err.reader().readAllArrayList(&obf_err, 1024 * 1024);
        const obf_term = try obf_child.wait();
        if (obf_term == .Exited and obf_term.Exited == 0) {
            const run_argv = &[_][]const u8{"./output_obf"};
            var run_child = std.process.Child.init(run_argv, allocator);
            run_child.stdout_behavior = .Pipe;
            run_child.stderr_behavior = .Pipe;
            try run_child.spawn();
            var run_out = std.ArrayList(u8).init(allocator);
            defer run_out.deinit();
            if (run_child.stdout) |out| try out.reader().readAllArrayList(&run_out, 1024 * 1024);
            const run_term = try run_child.wait();
            if (run_term == .Exited and run_term.Exited == 0) {
                const expected =
                    \\S3CR3T_MARKER_XYZZY
                    \\hello bob
                    \\caught
                    \\done
                ;
                const actual = std.mem.trim(u8, run_out.items, "\n\r\t ");
                if (std.mem.eql(u8, actual, expected)) {
                    const markers = [_][]const u8{ "S3CR3T_MARKER_XYZZY", "greet", "test_obf_temp.bob" };
                    const bin = std.fs.cwd().readFileAlloc(allocator, "output_obf", 64 * 1024 * 1024) catch null;
                    defer if (bin) |b| allocator.free(b);
                    var no_leak = true;
                    if (bin) |b| {
                        for (markers) |m| {
                            if (std.mem.indexOf(u8, b, m) != null) {
                                no_leak = false;
                                std.debug.print("[FAIL] [obfuscate] binary contains readable '{s}'\n", .{m});
                            }
                        }
                    } else {
                        no_leak = false;
                        std.debug.print("[FAIL] [obfuscate] could not read obfuscated binary for leak check\n", .{});
                    }
                    if (no_leak) {
                        total_passed += 1;
                        std.debug.print("[PASS] [obfuscate]\n", .{});
                    } else {
                        total_failed += 1;
                    }
                } else {
                    total_failed += 1;
                    std.debug.print("[FAIL] [obfuscate] output mismatch\n  expected\n{s}\n  actual\n{s}\n", .{ expected, actual });
                }
            } else {
                total_failed += 1;
                std.debug.print("[FAIL] [obfuscate] obfuscated binary exited with code {}\n", .{run_term});
            }
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [obfuscate] obfuscated build failed: {s}\n", .{obf_err.items});
        }

        std.fs.cwd().deleteFile(obf_file) catch {};
        std.fs.cwd().deleteFile("output_obf") catch {};
        std.fs.cwd().deleteFile("output_obf.ll") catch {};
    }

    if (total_failed > 0) std.process.exit(1);
}
