!
! Copyright (C) 2013 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!----------------------------------------------------------------------------
MODULE mp_global
  !----------------------------------------------------------------------------
  !
  ! ... Wrapper module, for compatibility. Contains a few "leftover" variables
  ! ... used for checks (all the *_file variables, read from data file),
  ! ... plus the routine mp_startup initializing MPI, plus the
  ! ... routine mp_global_end stopping MPI.
  ! ... Do not use this module to reference variables (e.g. communicators)
  ! ... belonging to each of the various parallelization levels:
  ! ... use the specific modules instead
  !
  USE mp_world, ONLY: mp_world_start, mp_world_end
  USE mp_images
  USE mp_pools
  USE mp_pots
  USE mp_bands
  USE mp_diag
  !
  IMPLICIT NONE 
  SAVE
  !
  ! ... number of processors for the various groups: values read from file
  !
  INTEGER :: nproc_file = 1
  INTEGER :: nproc_image_file = 1
  INTEGER :: nproc_pool_file  = 1
  INTEGER :: nproc_pot_file = 1
  INTEGER :: nproc_ortho_file = 1
  INTEGER :: nproc_bgrp_file  = 1
  INTEGER :: ntask_groups_file= 1
  !
CONTAINS
  !
  !-----------------------------------------------------------------------
  SUBROUTINE mp_startup ( my_world_comm, start_images )
    !-----------------------------------------------------------------------
    ! ... This wrapper subroutine initializes all parallelization levels.
    ! ... If option with_images=.true., processes are organized into images,
    ! ... each performing a quasi-indipendent calculation, such as a point
    ! ..  in configuration space (NEB) or a phonon irrep (PHonon)
    ! ... Within each image processes are further subdivided into various
    ! ... groups and parallelization levels
    !
    USE command_line_options, ONLY : get_command_line, &
        nimage_, npool_, npot_, ndiag_, nband_, ntg_
    USE parallel_include
    !
    IMPLICIT NONE
    INTEGER, INTENT(IN), OPTIONAL :: my_world_comm
    LOGICAL, INTENT(IN), OPTIONAL :: start_images
    LOGICAL :: do_images
    INTEGER :: my_comm
    !
    my_comm = MPI_COMM_WORLD
    IF ( PRESENT(my_world_comm) ) my_comm = my_world_comm
    !
    CALL mp_world_start( my_comm )
    CALL get_command_line ( )
    !
    do_images = .FALSE.
    IF ( PRESENT(start_images) ) do_images = start_images
    IF ( do_images ) THEN
       CALL mp_start_images ( nimage_, world_comm )
    ELSE
       CALL mp_init_image ( world_comm  )
    END IF
    !
    CALL mp_start_pots  ( npot_, intra_image_comm )
    CALL mp_start_pools ( npool_, intra_pot_comm )
    CALL mp_start_bands ( nband_, ntg_, intra_pool_comm )
    CALL mp_start_diag  ( ndiag_, intra_bgrp_comm )
    !
    RETURN
    !
  END SUBROUTINE mp_startup
  !
  !-----------------------------------------------------------------------
  SUBROUTINE mp_global_end ( )
    !-----------------------------------------------------------------------
    !
    USE mp, ONLY : mp_comm_free
    !
    CALL clean_ortho_group ( )
    CALL mp_comm_free ( intra_pot_comm )
    CALL mp_comm_free ( inter_pot_comm )
    CALL mp_comm_free ( intra_bgrp_comm )
    CALL mp_comm_free ( inter_bgrp_comm )
    CALL mp_comm_free ( intra_pool_comm )
    CALL mp_comm_free ( inter_pool_comm )
    CALL mp_world_end( )
    !
    RETURN
    !
  END SUBROUTINE mp_global_end
  !
END MODULE mp_global
