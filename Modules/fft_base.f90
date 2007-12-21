!
! Copyright (C) 2006 Quantum-ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
#include "f_defs.h"
!
!----------------------------------------------------------------------
! FFT base Module.
! Written by Carlo Cavazzoni 
!----------------------------------------------------------------------
!
!=----------------------------------------------------------------------=!
   MODULE fft_base
!=----------------------------------------------------------------------=!

        USE kinds, ONLY: DP
        USE parallel_include

        USE fft_types, ONLY: fft_dlay_descriptor

        IMPLICIT NONE
        
        TYPE ( fft_dlay_descriptor ) :: dfftp ! descriptor for dense grid
        TYPE ( fft_dlay_descriptor ) :: dffts ! descriptor for smooth grid
        TYPE ( fft_dlay_descriptor ) :: dfftb ! descriptor for box grids

        SAVE

        PRIVATE

        PUBLIC :: fft_scatter
        PUBLIC :: dfftp, dffts, dfftb, fft_dlay_descriptor


!=----------------------------------------------------------------------=!
      CONTAINS
!=----------------------------------------------------------------------=!
!
!
!
#if defined __NONBLOCKING_FFT
!
!   NON BLOCKING SCATTER, should be better on switched network 
!   like infiniband, ethernet, myrinet
!
!-----------------------------------------------------------------------
subroutine fft_scatter ( f_in, nrx3, nxx_, f_aux, ncp_, npp_, sign, use_tg )
  !-----------------------------------------------------------------------
  !
  ! transpose the fft grid across nodes
  ! a) From columns to planes (sign > 0)
  !
  !    "columns" (or "pencil") representation:
  !    processor "me" has ncp_(me) contiguous columns along z
  !    Each column has nrx3 elements for a fft of order nr3
  !    nrx3 can be =nr3+1 in order to reduce memory conflicts.
  !
  !    The transpose take places in two steps:
  !    1) on each processor the columns are divided into slices along z
  !       that are stored contiguously. On processor "me", slices for
  !       processor "proc" are npp_(proc)*ncp_(me) big
  !    2) all processors communicate to exchange slices
  !       (all columns with z in the slice belonging to "me"
  !        must be received, all the others must be sent to "proc")
  !    Finally one gets the "planes" representation:
  !    processor "me" has npp_(me) complete xy planes
  !
  !  b) From planes to columns (sign < 0)
  !
  !  Quite the same in the opposite direction
  !
  !  The output is overwritten on f_in ; f_aux is used as work space
  !
  !  If optional argument "use_tg" is true the subroutines performs
  !  the trasposition using the Task Groups distribution
  !
#ifdef __PARA
  USE parallel_include
#endif
  use mp_global,   ONLY : nproc_pool, me_pool, intra_pool_comm, nproc, &
                          my_image_id, nogrp, pgrp_comm
  USE kinds,       ONLY : DP
  USE task_groups, ONLY : nplist

  implicit none

  integer, intent(in)           :: nrx3, nxx_, sign, ncp_ (:), npp_ (:)
  complex (DP)                  :: f_in (nxx_), f_aux (nxx_)
  logical, optional, intent(in) :: use_tg

#ifdef __PARA

  INTEGER :: dest, from, k, offset1 (nproc), sendcount (nproc), &
       sdispls (nproc), recvcount (nproc), rdispls (nproc), &
       proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom, sh(nproc), &
       rh(nproc)
  !
  LOGICAL :: use_tg_ , lrcv, lsnd, tst(nproc), tsts(nproc), tstr(nproc)
  INTEGER :: istat( MPI_STATUS_SIZE )

#if defined __HPM
     !       CALL f_hpmstart( 10, 'scatter' )
#endif

  !
  !  Task Groups

  use_tg_ = .FALSE.

  IF( PRESENT( use_tg ) ) use_tg_ = use_tg
     
  me     = me_pool + 1
  !
  IF( use_tg_ ) THEN
    !  This is the number of procs. in the plane-wave group
     nprocp = nproc_pool / nogrp 
  ELSE
     nprocp = nproc_pool
  END IF
  !
  IF( use_tg_ ) THEN
     gcomm = pgrp_comm
  ELSE
     gcomm = intra_pool_comm
  END IF
  !
  if ( nprocp == 1 ) return
  !
  call start_clock ('fft_scatter')
  !
  ! sendcount(proc): amount of data processor "me" must send to processor
  ! recvcount(proc): amount of data processor "me" must receive from
  !
  ! offset1(proc) is used to locate the slices to be sent to proc
  ! sdispls(proc)+1 is the beginning of data that must be sent to proc
  ! rdispls(proc)+1 is the beginning of data that must be received from pr
  !
  ierr = 0
  !
  if ( sign > 0 ) then
     !
     ! "forward" scatter from columns to planes
     !
     ! step one: store contiguously the slices
     !
     do proc = 1, nprocp

        IF( use_tg_ ) THEN
           gproc  = nplist( proc ) + 1
           IF( proc == 1 ) THEN
              offset1 ( proc ) = 1
           ELSE
              offset1 ( proc ) = offset1 (proc - 1) + npp_ ( nplist( proc - 1 ) + 1 )
           END IF
        ELSE
           gproc  = proc
           IF( proc == 1 ) THEN
              offset1 ( proc ) = 1
           ELSE
              offset1 ( proc ) = offset1 (proc - 1) + npp_ ( proc - 1 )
           END IF
        END IF
        !

        sendcount (proc) = npp_ ( gproc ) * ncp_ (me)
        recvcount (proc) = npp_ (me) * ncp_ ( gproc )

        IF( proc == 1 ) THEN
           sdispls (1) = 0
           rdispls (1) = 0
        ELSE
           sdispls (proc) = sdispls (proc - 1) + sendcount (proc - 1)
           rdispls (proc) = rdispls (proc - 1) + recvcount (proc - 1)
        END IF

        from = offset1 (proc)
        dest = 1 + sdispls (proc)

        !  optimize for large parallel execution, where npp_ ( gproc ) ~ 1
        !
        SELECT CASE ( npp_ ( gproc ) )
        CASE ( 1 )
           do k = 1, ncp_ (me)
              f_aux (dest + (k - 1) ) =  f_in (from + (k - 1) * nrx3 )
           enddo
        CASE ( 2 )
           do k = 1, ncp_ (me)
              f_aux ( dest + (k - 1) * 2 - 1 + 1 ) =  f_in ( from + (k - 1) * nrx3 - 1 + 1 )
              f_aux ( dest + (k - 1) * 2 - 1 + 2 ) =  f_in ( from + (k - 1) * nrx3 - 1 + 2 )
           enddo
        CASE ( 3 )
           do k = 1, ncp_ (me)
              f_aux ( dest + (k - 1) * 3 - 1 + 1 ) =  f_in ( from + (k - 1) * nrx3 - 1 + 1 )
              f_aux ( dest + (k - 1) * 3 - 1 + 2 ) =  f_in ( from + (k - 1) * nrx3 - 1 + 2 )
              f_aux ( dest + (k - 1) * 3 - 1 + 3 ) =  f_in ( from + (k - 1) * nrx3 - 1 + 3 )
           enddo
        CASE ( 4 )
           do k = 1, ncp_ (me)
              f_aux ( dest + (k - 1) * 4 - 1 + 1 ) =  f_in ( from + (k - 1) * nrx3 - 1 + 1 )
              f_aux ( dest + (k - 1) * 4 - 1 + 2 ) =  f_in ( from + (k - 1) * nrx3 - 1 + 2 )
              f_aux ( dest + (k - 1) * 4 - 1 + 3 ) =  f_in ( from + (k - 1) * nrx3 - 1 + 3 )
              f_aux ( dest + (k - 1) * 4 - 1 + 4 ) =  f_in ( from + (k - 1) * nrx3 - 1 + 4 )
           enddo
        CASE DEFAULT
           do k = 1, ncp_ (me)
              kdest = dest + (k - 1) * npp_ ( gproc ) - 1
              kfrom = from + (k - 1) * nrx3 - 1
              do i = 1, npp_ ( gproc )
                 f_aux ( kdest + i ) =  f_in ( kfrom + i )
              enddo
           enddo
        END SELECT
        !
        ! post the non-blocking send, f_aux can't be overwritten until operation has completed
        !
        call mpi_isend( f_aux( sdispls( proc ) + 1 ), sendcount( proc ), MPI_DOUBLE_COMPLEX, &
             proc-1, me, gcomm, sh( proc ), ierr )
        !
        if( ABS(ierr) /= 0 ) call errore ('fft_scatter', ' forward send info<>0', ABS(ierr) )
        !
     end do
     !
     ! step two: communication
     !
     do proc = 1, nprocp
        !
        ! maybe useless; ensures that no garbage is present in the output
        !
        IF( proc < nprocp ) THEN
           f_in( rdispls( proc ) + recvcount( proc ) + 1 : rdispls( proc + 1 ) ) = 0.0_DP
        ELSE
           f_in( rdispls( proc ) + recvcount( proc ) + 1 : SIZE( f_in )  ) = 0.0_DP
        END IF
        !
        ! now post the receive 
        !
        CALL mpi_irecv( f_in( rdispls( proc ) + 1 ), recvcount( proc ), MPI_DOUBLE_COMPLEX, &
             proc-1, MPI_ANY_TAG, gcomm, rh( proc ), ierr )
        !
        if( ABS(ierr) /= 0 ) call errore ('fft_scatter', ' forward receive info<>0', ABS(ierr) )
        !
     end do
     !
     lrcv = .false.
     lsnd = .false.
     tstr( 1 : nprocp )  = .false.
     tsts( 1 : nprocp )  = .false.
     !
     ! exit only when all test are true: message operation have completed
     !
     do while ( .not. lrcv .or. .not. lsnd )
        lrcv = .true.
        lsnd = .true.
        do proc = 1, nprocp
           !
           IF( .not. tstr( proc ) ) THEN
              call mpi_test( rh( proc ), tstr( proc ), istat, ierr )
              IF( tstr( proc ) ) THEN
                 ! free communication resources
                 call mpi_request_free( rh( proc ), ierr )
              END IF
           END IF
           !
           IF( .not. tsts( proc ) ) THEN
              call mpi_test( sh( proc ), tsts( proc ), istat, ierr )
              IF( tsts( proc ) ) THEN
                 ! free communication resources
                 call mpi_request_free( sh( proc ), ierr )
              END IF
           END IF
           !
           lrcv = lrcv .and. tstr( proc )
           lsnd = lsnd .and. tsts( proc )
           !
        end do
        !
     end do
     !
  else
     !
     !  "backward" scatter from planes to columns
     !
     do proc = 1, nprocp

        IF( use_tg_ ) THEN
           gproc  = nplist( proc ) + 1
           IF( proc == 1 ) THEN
              offset1 ( proc ) = 1
           ELSE
              offset1 ( proc ) = offset1 (proc - 1) + npp_ ( nplist( proc - 1 ) + 1 )
           END IF
        ELSE
           gproc  = proc
           IF( proc == 1 ) THEN
              offset1 ( proc ) = 1
           ELSE
              offset1 ( proc ) = offset1 (proc - 1) + npp_ ( proc - 1 )
           END IF
        END IF

        sendcount (proc) = npp_ ( gproc ) * ncp_ (me)
        recvcount (proc) = npp_ (me) * ncp_ ( gproc )

        IF( proc == 1 ) THEN
           sdispls (1) = 0
           rdispls (1) = 0
        ELSE
           sdispls (proc) = sdispls (proc - 1) + sendcount (proc - 1)
           rdispls (proc) = rdispls (proc - 1) + recvcount (proc - 1)
        END IF

        !  post the non blocking send

        call mpi_isend( f_in( rdispls( proc ) + 1 ), recvcount( proc ), MPI_DOUBLE_COMPLEX, &
             proc-1, me, gcomm, sh( proc ), ierr )
        if( ABS(ierr) /= 0 ) call errore ('fft_scatter', ' backward send info<>0', ABS(ierr) )

        !  post the non blocking receive

        CALL mpi_irecv( f_aux( sdispls( proc ) + 1 ), sendcount( proc ), MPI_DOUBLE_COMPLEX, &
             proc-1, MPI_ANY_TAG, gcomm, rh(proc), ierr )
        if( ABS(ierr) /= 0 ) call errore ('fft_scatter', ' backward receive info<>0', ABS(ierr) )

     end do
     !
     lrcv = .false.
     lsnd = .false.
     tstr( 1 : nprocp )  = .false.
     tsts( 1 : nprocp )  = .false.
     !
     ! exit only when all test are true: message hsve been sent and received
     !
     do while ( .not. lsnd )
        !
        lsnd = .true.
        !
        do proc = 1, nprocp
           !
           IF( .not. tsts( proc ) ) THEN
              call mpi_test( sh( proc ), tsts( proc ), istat, ierr )
              IF( tsts( proc ) ) THEN
                 ! free communication resources
                 call mpi_request_free( sh( proc ), ierr )
              END IF
           END IF

           lsnd = lsnd .and. tsts( proc )

        end do

     end do
     !
     do while ( .not. lrcv )
        !
        lrcv = .true.
        !
        do proc = 1, nprocp

           IF( .not. tstr( proc ) ) THEN

              call mpi_test( rh( proc ), tstr( proc ), istat, ierr )

              IF( tstr( proc ) ) THEN

                 from = 1 + sdispls (proc)
                 dest = offset1 (proc)
                 IF( use_tg_ ) THEN
                    gproc = nplist(proc)+1
                 ELSE
                    gproc = proc
                 END IF
                 !  
                 !  optimize for large parallel execution, where npp_ ( gproc ) ~ 1
                 !
                 SELECT CASE ( npp_ ( gproc ) )
                 CASE ( 1 )
                    do k = 1, ncp_ (me) 
                       f_in ( dest + (k - 1) * nrx3 ) = f_aux ( from + k - 1 )
                    end do
                 CASE ( 2 )
                    do k = 1, ncp_ ( me )
                       f_in ( dest + (k - 1) * nrx3 - 1 + 1 ) = f_aux( from + (k - 1) * 2 - 1 + 1 )
                       f_in ( dest + (k - 1) * nrx3 - 1 + 2 ) = f_aux( from + (k - 1) * 2 - 1 + 2 )
                    enddo
                 CASE ( 3 )
                    do k = 1, ncp_ ( me )
                       f_in ( dest + (k - 1) * nrx3 - 1 + 1 ) = f_aux( from + (k - 1) * 3 - 1 + 1 )
                       f_in ( dest + (k - 1) * nrx3 - 1 + 2 ) = f_aux( from + (k - 1) * 3 - 1 + 2 )
                       f_in ( dest + (k - 1) * nrx3 - 1 + 3 ) = f_aux( from + (k - 1) * 3 - 1 + 3 )
                    enddo
                 CASE ( 4 )
                    do k = 1, ncp_ ( me )
                       f_in ( dest + (k - 1) * nrx3 - 1 + 1 ) = f_aux( from + (k - 1) * 4 - 1 + 1 )
                       f_in ( dest + (k - 1) * nrx3 - 1 + 2 ) = f_aux( from + (k - 1) * 4 - 1 + 2 )
                       f_in ( dest + (k - 1) * nrx3 - 1 + 3 ) = f_aux( from + (k - 1) * 4 - 1 + 3 )
                       f_in ( dest + (k - 1) * nrx3 - 1 + 4 ) = f_aux( from + (k - 1) * 4 - 1 + 4 )
                    enddo
                 CASE DEFAULT
                    do k = 1, ncp_ ( me )
                       kdest = dest + (k - 1) * nrx3 - 1
                       kfrom = from + (k - 1) * npp_ ( gproc ) - 1
                       do i = 1, npp_ ( gproc )
                          f_in ( kdest + i ) = f_aux( kfrom + i )
                       enddo
                    enddo
                 END SELECT

                 ! free communication resources
                 call mpi_request_free( rh( proc ), ierr )

              END IF

           END IF

           lrcv = lrcv .and. tstr( proc )

        end do

     end do

  endif

  call stop_clock ('fft_scatter')

#endif

#if defined __HPM
     !       CALL f_hpmstop( 10 )
#endif

  return

end subroutine fft_scatter
!
!
!
#else
!
!   ALLTOALL based SCATTER, should be better on network 
!   with a defined topology, like on bluegene and cray machine
!
!-----------------------------------------------------------------------
subroutine fft_scatter ( f_in, nrx3, nxx_, f_aux, ncp_, npp_, sign, use_tg )
  !-----------------------------------------------------------------------
  !
  ! transpose the fft grid across nodes
  ! a) From columns to planes (sign > 0)
  !
  !    "columns" (or "pencil") representation:
  !    processor "me" has ncp_(me) contiguous columns along z
  !    Each column has nrx3 elements for a fft of order nr3
  !    nrx3 can be =nr3+1 in order to reduce memory conflicts.
  !
  !    The transpose take places in two steps:
  !    1) on each processor the columns are divided into slices along z
  !       that are stored contiguously. On processor "me", slices for
  !       processor "proc" are npp_(proc)*ncp_(me) big
  !    2) all processors communicate to exchange slices
  !       (all columns with z in the slice belonging to "me"
  !        must be received, all the others must be sent to "proc")
  !    Finally one gets the "planes" representation:
  !    processor "me" has npp_(me) complete xy planes
  !
  !  b) From planes to columns (sign < 0)
  !
  !  Quite the same in the opposite direction
  !
  !  The output is overwritten on f_in ; f_aux is used as work space
  !
  !  If optional argument "use_tg" is true the subroutines performs
  !  the trasposition using the Task Groups distribution
  !
#ifdef __PARA
  USE parallel_include
#endif
  use mp_global,   ONLY : nproc_pool, me_pool, intra_pool_comm, nproc, &
                          my_image_id, nogrp, pgrp_comm
  USE kinds,       ONLY : DP
  USE task_groups, ONLY : nplist

  implicit none

  integer, intent(in)           :: nrx3, nxx_, sign, ncp_ (:), npp_ (:)
  complex (DP)                  :: f_in (nxx_), f_aux (nxx_)
  logical, optional, intent(in) :: use_tg

#ifdef __PARA

  integer :: dest, from, k, offset1 (nproc), sendcount (nproc), &
       sdispls (nproc), recvcount (nproc), rdispls (nproc), &
       proc, ierr, me, nprocp, gproc, gcomm, i, kdest, kfrom
  !
  LOGICAL :: use_tg_

#if defined __HPM
     !       CALL f_hpmstart( 10, 'scatter' )
#endif

  !
  !  Task Groups

  use_tg_ = .FALSE.

  IF( PRESENT( use_tg ) ) use_tg_ = use_tg
     
  me     = me_pool + 1
  !
  IF( use_tg_ ) THEN
    !  This is the number of procs. in the plane-wave group
     nprocp = nproc_pool / nogrp 
  ELSE
     nprocp = nproc_pool
  END IF
  !
  if (nprocp.eq.1) return
  !
  call start_clock ('fft_scatter')
  !
  ! sendcount(proc): amount of data processor "me" must send to processor
  ! recvcount(proc): amount of data processor "me" must receive from
  !
  IF( use_tg_ ) THEN
     do proc = 1, nprocp
        gproc = nplist( proc ) + 1
        sendcount (proc) = npp_ ( gproc ) * ncp_ (me)
        recvcount (proc) = npp_ (me) * ncp_ ( gproc )
     end do 
  ELSE
     do proc = 1, nprocp
        sendcount (proc) = npp_ (proc) * ncp_ (me)
        recvcount (proc) = npp_ (me) * ncp_ (proc)
     end do
  END IF
  !
  ! offset1(proc) is used to locate the slices to be sent to proc
  ! sdispls(proc)+1 is the beginning of data that must be sent to proc
  ! rdispls(proc)+1 is the beginning of data that must be received from pr
  !
  offset1 (1) = 1
  IF( use_tg_ ) THEN
     do proc = 2, nprocp
        gproc = nplist( proc - 1 ) + 1
        offset1 (proc) = offset1 (proc - 1) + npp_ ( gproc )
     enddo
  ELSE
     do proc = 2, nprocp
        offset1 (proc) = offset1 (proc - 1) + npp_ (proc - 1)
     enddo
  END IF

  sdispls (1) = 0
  rdispls (1) = 0
  do proc = 2, nprocp
     sdispls (proc) = sdispls (proc - 1) + sendcount (proc - 1)
     rdispls (proc) = rdispls (proc - 1) + recvcount (proc - 1)
  enddo
  !

  ierr = 0
  if (sign.gt.0) then
     !
     ! "forward" scatter from columns to planes
     !
     ! step one: store contiguously the slices
     !
     do proc = 1, nprocp
        from = offset1 (proc)
        dest = 1 + sdispls (proc)
        IF( use_tg_ ) THEN
           gproc = nplist(proc)+1
        ELSE
           gproc = proc
        END IF
        !
        !  optimize for large parallel execution, where npp_ ( gproc ) ~ 1
        !
        IF( npp_ ( gproc ) > 128 ) THEN
           do k = 1, ncp_ (me)
              call DCOPY (2 * npp_ ( gproc ), f_in (from + (k - 1) * nrx3), &
                   1, f_aux (dest + (k - 1) * npp_ ( gproc ) ), 1)
           enddo
        ELSE IF( npp_ ( gproc ) == 1 ) THEN
           do k = 1, ncp_ (me)
              f_aux (dest + (k - 1) ) =  f_in (from + (k - 1) * nrx3 )
           enddo
        ELSE
           do k = 1, ncp_ (me)
              kdest = dest + (k - 1) * npp_ ( gproc ) - 1
              kfrom = from + (k - 1) * nrx3 - 1
              do i = 1, npp_ ( gproc )
                 f_aux ( kdest + i ) =  f_in ( kfrom + i )
              enddo
           enddo
        END IF
     enddo
     !
     ! maybe useless; ensures that no garbage is present in the output
     !
     f_in = 0.0_DP
     !
     ! step two: communication
     !
     IF( use_tg_ ) THEN
        gcomm = pgrp_comm
     ELSE
        gcomm = intra_pool_comm
     END IF

     call mpi_barrier (gcomm, ierr)  ! why barrier? for buggy openmpi over ib

     call mpi_alltoallv (f_aux(1), sendcount, sdispls, MPI_DOUBLE_COMPLEX, f_in(1), &
          recvcount, rdispls, MPI_DOUBLE_COMPLEX, gcomm, ierr)

     if( ABS(ierr) /= 0 ) call errore ('fft_scatter', 'info<>0', ABS(ierr) )
     !
  else
     !
     !  "backward" scatter from planes to columns
     !
     !  step two: communication
     !
     IF( use_tg_ ) THEN
        gcomm = pgrp_comm
     ELSE
        gcomm = intra_pool_comm
     END IF

     call mpi_barrier (gcomm, ierr)  ! why barrier? for buggy openmpi over ib

     call mpi_alltoallv (f_in(1), recvcount, rdispls, MPI_DOUBLE_COMPLEX, f_aux(1), &
          sendcount, sdispls, MPI_DOUBLE_COMPLEX, gcomm, ierr)

     if( ABS(ierr) /= 0 ) call errore ('fft_scatter', 'info<>0', ABS(ierr) )
     !
     !  step one: store contiguously the columns
     !
     f_in = 0.0_DP
     !
     do proc = 1, nprocp
        from = 1 + sdispls (proc)
        dest = offset1 (proc)
        IF( use_tg_ ) THEN
           gproc = nplist(proc)+1
        ELSE
           gproc = proc
        END IF
        !  
        !  optimize for large parallel execution, where npp_ ( gproc ) ~ 1
        !
        IF( npp_ ( gproc ) > 128 ) THEN
           do k = 1, ncp_ (me) 
              call DCOPY ( 2 * npp_ ( gproc ), f_aux (from + (k - 1) * npp_ ( gproc ) ), 1, &
                                            f_in  (dest + (k - 1) * nrx3 ), 1 )
           enddo
        ELSE IF ( npp_ ( gproc ) == 1 ) THEN
           do k = 1, ncp_ (me) 
              f_in ( dest + (k - 1) * nrx3 ) = f_aux ( from + (k - 1) )
           end do
        ELSE
           do k = 1, ncp_ (me)
              kdest = dest + (k - 1) * nrx3 - 1
              kfrom = from + (k - 1) * npp_ ( gproc ) - 1
              do i = 1, npp_ ( gproc )
                 f_in ( kdest + i ) = f_aux( kfrom + i )
              enddo
           enddo
        END IF

     enddo

  endif

  call stop_clock ('fft_scatter')

#endif

#if defined __HPM
     !       CALL f_hpmstop( 10 )
#endif

  return

end subroutine fft_scatter

#endif

!=----------------------------------------------------------------------=!
   END MODULE fft_base
!=----------------------------------------------------------------------=!
