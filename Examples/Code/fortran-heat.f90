program heat
  implicit none
  integer, parameter :: n = 10, steps = 100
  real(8) :: u(n), unew(n)
  integer :: i, t

  u = 0.0d0
  u(1) = 100.0d0
  do t = 1, steps
    do i = 2, n - 1
      unew(i) = u(i) + 0.25d0 * (u(i - 1) - 2.0d0 * u(i) + u(i + 1))
    end do
    u(2:n-1) = unew(2:n-1)
  end do
  print '(10F8.2)', u
end program heat
