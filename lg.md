# boblang all expressions

## comments
# line comment (all dialects)
// line comment (all dailects)
/* block comment */ (python-like, c-like)
-- line comment (lua-like)
; line comment (in package lib.bob files)

## doc comments
"""doc comment above a func or class"""
func foo():
    pass

## literals
42
-1
3.14
-2.71
"hello"
'hello'
True
False
nil

## big integers and big floats
123456789012345678901234567890   # bigi (arbitrary precision int)
3.14159265358979323846264338327  # bigf (arbitrary precision float)
x: bigi = 12345678901234567890
y: bigf = 3.14159265358979323846
both are
## arithmetic
a + b
a - b
a * b
a / b
a // b
a % b
a ** b
a ^ b

## comparison
a == b
a != b
a < b
a > b
a <= b
a >= b
x in list      # membership: true if x is an element of the list
k in dict      # membership: true if k is a key in the dict
sub in string  # membership: true if sub is a substring

## boolean
a and b
a or b
not a
!a
a && b
a || b

## assignment
x = 5
x += 1
x *= 2
x: int = 5
x: float = 3.14
x: str = "hello"
x: bool = True
x: any = 42

## typed var
x: int = 5      # stored as raw i64
y: float = 3.14 # stored as raw double
z: str = "hi"   # stored as boxed ptr

## pass
if x > 0:
    pass
func empty():
    pass

## lists
[1, 2, 3]
[]
items[0]
items[1:3]
items[:2]
items[1:]
items[0] = 99

## dicts
{"a": 1, "b": 2}
{}
scores["alice"]
scores["bob"] = 25

## property access
obj.prop
obj.method()
obj?.prop
obj?.method()

## string interpolation
"value is {{x}}"
"hello {{name}} you are {{age}}"
"{{a}} + {{b}} = {{a + b}}"

## if
if x > 0:
    print("pos")
elif x == 0:
    print("zero")
else:
    print("neg")

## while
while x > 0:
    print(x)
    x = x - 1

## for
for i in range(5):
    print(i)

for item in my_list:
    print(item)

for key in my_dict:
    print(key)

## break
while True:
    if done:
        break

## func
func foo():
    return 42

func add(a, b):
    return a + b

func greet(name: str):
    print("hello", name)

func divide(a: int, b: int) float:
    return a / b

func repeat(msg, times=3):
    i = 0
    while i < times:
        print(msg)
        i = i + 1

func greet(name="world"):
    print("hello", name)

func safe_print(msg?):
    if msg != nil:
        print(msg)

func greet(name?: str):
    if name != nil:
        print("Hello,", name)

## closures
func make_counter():
    count = 0
    func increment():
        count = count + 1
        return count
    return increment

## decorators
func logger(f):
    print("calling", f)
    return f

@logger
func foo():
    print("hello")

func add_hello(f):
    print("hello")
    return f

func add_world(f):
    print("world")
    return f

@add_hello
@add_world
func hello():
    print("hello")
## lists
x = [1 , "hello", False]  # untyped list
y: list[int] = [1 , 2, 3] # typed list
## function props
func test(a, b=10):
    print(a + b)

p = test.props
print(p.name)     # "test"
print(p.arity)    # 2
print(p.required) # 1

class MyClass:
    func _init_():
        pass
    func greet(name):
        print("hello", name)

obj = MyClass()
m = obj.greet
print(m.props.name)  # "greet"
print(m.props.arity) # 2

func add_method(cls):
    cls.greeting = "hello"
    return cls

@add_method
class MyClass:
    pass

## decorators on methods
class MyClass:
    @method_decorator
    func foo():
        pass

    @dec1
    @dec2
    func bar():
        pass

## class
class Animal:
    func _init_(name):
        self.name = name
    func speak():
        print(self.name)

## inheritance (_prev_ chains to parent ctor)
class Dog(Animal):
    func _init_(_prev_, breed):
        self.breed = breed
    func bark():
        print(self.breed, "barks")
    func speak():
        print(self.name, "the", self.breed, "barks")

class MyClass:
    private func helper():
        return 42
    func get_val():
        return self.helper()

## enums
enum Color { Red, Green, Blue }        # single-line declaration
print(Color.Red)                       # 0
print(Color.Blue)                      # 2

enum Status { OK = 200, NotFound = 404 }   # explicit integer values
print(Status.OK)                       # 200

enum Direction { North, East = 10, South, West }
print(Direction.North)                 # 0
print(Direction.East)                  # 10
print(Direction.South)                 # 11  (auto-increments after explicit)
print(Direction.West)                  # 12

c: Color = Color.Green                 # enum name works as a type annotation
print(c)                               # 1

print(Color.Red + 1)                   # 1  (integer members are real ints)
print(Status.OK + Status.NotFound)     # 604

if c == Color.Green:                   # compare members
    print("green")

enum members work inside generic lists:

palette: list[Color] = [Color.Red, Color.Blue]
print(palette[0])                      # 0
palette.append(Color.Green)

### any value type

Members can hold any value — ints, strings, floats, bools, nil, lists,
dicts, and even other enum members:

enum color { R = "red", G = "green", B = "blue" }
print(color.G)                         # green
print(type(color.B))                   # str

enum num { A = 5, B = 3.14, C = true, D }
print(num.B)                           # 3.14
print(num.D)                           # 6   (auto-increments after an int)

enum mixed { X, Y = "hi", Z }          # non-int values leave the counter alone
print(mixed.X)                         # 0
print(mixed.Y)                         # hi
print(mixed.Z)                         # 1

enum flags { Alpha, Beta = 100, Gamma, Delta = -1, Epsilon }
print(flags.Alpha)                     # 0
print(flags.Beta)                      # 100
print(flags.Gamma)                     # 101
print(flags.Delta)                     # -1
print(flags.Epsilon)                   # 0   (next auto value after -1)

enum other { P = 10, Q }
enum ref { One = other.P, Two = other.Q }   # reference other members
print(ref.One)                         # 10

enum listy { Nums = [1, 2, 3] }        # list values
print(len(listy.Nums))                 # 3

enum csv { A = "a,b,c" }               # commas / quotes inside values are fine
print(csv.A)                           # a,b,c
## try
try:
    risky_operation()
except:
    print("error")

try:
    risky_operation()
except e:
    print("caught:", e)   # e holds the error message

## import
import "file.c" as cmod
import "file.go" as gomod
import "file.bob" as bobmod
import package-name as pkg

## export
export math.add as my_add
export my_func as my_func

## builtins
print("hello", 42)
input("enter: ")
int("42")
float("3.14")
str(42)
bool(1)
type(x)
len([1, 2, 3])
range(5)
range(1, 10)
range(0, 10, 2)
min(1, 2)
max(1, 2)
clamp(x, 0, 10)
ascii("A")
chr(65)
get_args()

## reading a float from stdin
x = float(input("enter a float: ")) # input() reads a line, float() parses it
print(x * 2)

## list methods
items.append(4)
items.pop()
items.clear()
items.reverse()
items.sort()

## string ops
"hello" + " world"
str(42) + " is the answer"

## type annotations
x: int = 5
x: float = 3.14
x: str = "hello"
x: bool = True
x: any = 42
x: bigi = 12345678901234567890
x: bigf = 3.14159265358979323846

## type-safe reassignment
x: int = 0
x = "str"      # Compile Error: 'x' was annotated as 'int' but assigned a 'str' value
x = 42         # OK: matches the declared type
y: str = "hi"
y = "there"    # OK: matches the declared type
z = 0
z = "str"      # OK: z is untyped (no annotation)

## null safety
nil            # null literal (alias: null)
val = a ?? b   # null-coalescing: a if a is not nil, else b
val = obj?.p   # optional property: nil if obj is nil, else obj.p
val = obj?.m() # optional call: nil if obj is nil, else obj.m()

## null-safe assignment
x = returnsnull()    # Runtime Error: cannot assign nil to a non-nullable variable
x? = returnsnull()   # OK: '?=' marks x as nullable and accepts nil
x? = nil             # OK
x = nil              # Compile Error: use '?=' to make it nullable

## functional list methods
list.map(f)      # new list: [f(x) for each x]
list.filter(f)   # new list: [x for each x where f(x) is truthy]
list.reduce(f)   # fold: f(f(f(a0, a1), a2), ...) starting with the first element

## expression types
42          # int literal
3.14        # float literal
"hello"     # string literal
True        # bool literal
False       # bool literal
nil         # nil literal
x           # var reference
foo(x, y)   # function call
obj.m()     # method call
obj.p       # property access
obj?.p      # optional property access
obj?.m()    # optional method call
[1, 2]      # list literal
{"a": 1}    # dict literal
items[0]    # index access
items[1:3]  # slice

## exmple conf

dialect: "python-like"
output: "gl_demo"
optimize: "ReleaseFast"
version: "1.0.0"
entry: "main.bob"
ttarget: "windows"
rect_color: "0.8, 0.2, 0.3"
packages: {
    /home/user/Desktop/proj/boblang-stack/boblang-opengl as boblang-opengl
}

hope ya like it