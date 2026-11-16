program BubbleSort;

const
  N = 6;

var
  A: array[1..N] of Integer = (5, 2, 9, 1, 7, 3);
  I, J, Tmp: Integer;

begin
  for I := 1 to N - 1 do
    for J := 1 to N - I do
      if A[J] > A[J + 1] then
      begin
        Tmp := A[J]; A[J] := A[J + 1]; A[J + 1] := Tmp;
      end;
  for I := 1 to N do Write(A[I], ' ');
  WriteLn;
end.
